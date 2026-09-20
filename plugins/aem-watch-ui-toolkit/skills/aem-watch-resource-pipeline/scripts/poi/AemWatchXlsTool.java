import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.apache.poi.hssf.usermodel.HSSFCell;
import org.apache.poi.hssf.usermodel.HSSFRow;
import org.apache.poi.hssf.usermodel.HSSFSheet;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.poifs.filesystem.DirectoryEntry;
import org.apache.poi.poifs.filesystem.DocumentEntry;
import org.apache.poi.poifs.filesystem.DocumentInputStream;
import org.apache.poi.poifs.filesystem.Entry;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.DataFormatter;

public final class AemWatchXlsTool {
    private static final String VERSION = "1";
    private static final Base64.Decoder BASE64_DECODER = Base64.getDecoder();
    private static final Base64.Encoder BASE64_ENCODER = Base64.getEncoder();

    private AemWatchXlsTool() {
    }

    public static void main(String[] args) {
        try {
            if (args.length == 1 && "--version".equals(args[0])) {
                System.out.println("AEM_WATCH_XLS_TOOL=" + VERSION);
                System.out.println("POI=" + HSSFWorkbook.class.getPackage().getImplementationVersion());
                return;
            }
            if (args.length != 2 || !"--job".equals(args[0])) {
                throw new IllegalArgumentException("usage: AemWatchXlsTool --job <job-file>");
            }
            Job job = readJob(Paths.get(args[1]));
            execute(job);
        } catch (Exception error) {
            System.err.println("AEM_WATCH_XLS_ERROR=" + error.getMessage());
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static Job readJob(Path path) throws IOException {
        Job job = new Job();
        try (BufferedReader reader = Files.newBufferedReader(path, StandardCharsets.UTF_8)) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }
                int separator = line.indexOf('=');
                if (separator < 1) {
                    throw new IllegalArgumentException("invalid job line: " + line);
                }
                String name = line.substring(0, separator);
                String value = line.substring(separator + 1);
                if ("version".equals(name)) {
                    job.version = value;
                } else if ("mode".equals(name)) {
                    job.apply = "apply".equals(value);
                    if (!job.apply && !"dry-run".equals(value)) {
                        throw new IllegalArgumentException("invalid mode: " + value);
                    }
                } else if ("input".equals(name)) {
                    job.input = new File(decode(value));
                } else if ("output".equals(name)) {
                    job.output = value.isEmpty() ? null : new File(decode(value));
                } else if ("keyColumn".equals(name)) {
                    job.keyColumn = Integer.parseInt(value);
                } else if ("languageCodeRow".equals(name)) {
                    job.languageCodeRow = Integer.parseInt(value);
                } else if ("dataStartRow".equals(name)) {
                    job.dataStartRow = Integer.parseInt(value);
                } else if ("language".equals(name)) {
                    String[] fields = value.split("\\|", -1);
                    requireFieldCount(name, fields, 2);
                    job.languageColumns.put(decode(fields[0]), Integer.parseInt(fields[1]));
                } else if ("active".equals(name)) {
                    job.activeLanguages.add(decode(value));
                } else if ("set".equals(name)) {
                    String[] fields = value.split("\\|", -1);
                    requireFieldCount(name, fields, 3);
                    job.updates.add(new Update(decode(fields[0]), decode(fields[1]), decode(fields[2])));
                } else {
                    throw new IllegalArgumentException("unknown job field: " + name);
                }
            }
        }
        job.validate();
        return job;
    }

    private static void requireFieldCount(String name, String[] fields, int expected) {
        if (fields.length != expected) {
            throw new IllegalArgumentException("invalid " + name + " field count");
        }
    }

    private static void execute(Job job) throws Exception {
        int plannedChanges = 0;
        int changedCells = 0;
        Path directWorkbook = null;
        Map<String, Integer> rowsByKey = new LinkedHashMap<>();
        List<String> distinctKeys = distinctKeys(job.updates);

        try (POIFSFileSystem fileSystem = new POIFSFileSystem(job.input, true);
             HSSFWorkbook workbook = new HSSFWorkbook(fileSystem, true)) {
            HSSFSheet sheet = workbook.getSheetAt(0);
            List<String> actualLanguages = readActiveLanguages(sheet, job);
            if (!actualLanguages.equals(job.activeLanguages)) {
                throw new IllegalStateException(
                    "active languages mismatch: expected " + job.activeLanguages +
                    ", workbook " + actualLanguages
                );
            }

            for (String key : distinctKeys) {
                rowsByKey.put(key, findUniqueRow(sheet, job, key));
            }

            for (Update update : job.updates) {
                Integer column = job.languageColumns.get(update.language);
                if (column == null) {
                    throw new IllegalStateException("unknown language: " + update.language);
                }
                if (!job.activeLanguages.contains(update.language)) {
                    throw new IllegalStateException("inactive language update: " + update.language);
                }

                int rowNumber = rowsByKey.get(update.key);
                HSSFRow row = sheet.getRow(rowNumber - 1);
                HSSFCell cell = row.getCell(column - 1);
                String current = cellText(cell);
                printText(update, rowNumber, column, current);
                if (!current.equals(update.value)) {
                    plannedChanges++;
                    if (job.apply) {
                        if (cell == null) {
                            cell = row.createCell(column - 1, CellType.STRING);
                        }
                        cell.setCellValue(update.value);
                        changedCells++;
                    }
                }
            }

            for (String key : distinctKeys) {
                int rowNumber = rowsByKey.get(key);
                HSSFRow row = sheet.getRow(rowNumber - 1);
                List<String> missing = new ArrayList<>();
                for (Map.Entry<String, Integer> language : job.languageColumns.entrySet()) {
                    if (job.activeLanguages.contains(language.getKey())) {
                        continue;
                    }
                    if (cellText(row.getCell(language.getValue() - 1)).trim().isEmpty()) {
                        missing.add(language.getKey());
                    }
                }
                System.out.println("MISSING_OPTIONAL=" + encode(key) + "|" + String.join(",", missing));
            }

            if (job.apply) {
                Path outputParent = job.output.toPath().toAbsolutePath().getParent();
                if (outputParent == null) {
                    throw new IllegalStateException("output has no parent directory");
                }
                Files.createDirectories(outputParent);
                directWorkbook = Files.createTempFile(outputParent, ".codex-poi-workbook-", ".xls");
                try (FileOutputStream stream = new FileOutputStream(directWorkbook.toFile())) {
                    workbook.write(stream);
                }
            }
        }

        if (job.apply) {
            try {
                writePreservedContainer(job.input, directWorkbook.toFile(), job.output);
                verifyOutput(job, rowsByKey);
                verifyContainer(job.input, job.output);
            } catch (Exception error) {
                Files.deleteIfExists(job.output.toPath());
                throw error;
            } finally {
                if (directWorkbook != null) {
                    Files.deleteIfExists(directWorkbook);
                }
            }
        }

        System.out.println("ACTIVE_LANGUAGES=" + String.join(",", job.activeLanguages));
        System.out.println("PLANNED_CHANGES=" + plannedChanges);
        System.out.println("CHANGED_CELLS=" + changedCells);
        if (job.apply) {
            System.out.println("NON_WORKBOOK_STREAMS_PRESERVED=true");
        }
        System.out.println("RESULT=SUCCESS");
    }

    private static List<String> distinctKeys(List<Update> updates) {
        List<String> result = new ArrayList<>();
        for (Update update : updates) {
            if (!result.contains(update.key)) {
                result.add(update.key);
            }
        }
        return result;
    }

    private static List<String> readActiveLanguages(HSSFSheet sheet, Job job) {
        HSSFRow row = sheet.getRow(job.languageCodeRow - 1);
        if (row == null) {
            throw new IllegalStateException("language code row is missing");
        }
        List<String> active = new ArrayList<>();
        for (Map.Entry<String, Integer> language : job.languageColumns.entrySet()) {
            String code = cellText(row.getCell(language.getValue() - 1)).trim();
            if (!code.isEmpty()) {
                active.add(code);
            }
        }
        return active;
    }

    private static int findUniqueRow(HSSFSheet sheet, Job job, String key) {
        int found = -1;
        int lastRow = sheet.getLastRowNum() + 1;
        for (int rowNumber = job.dataStartRow; rowNumber <= lastRow; rowNumber++) {
            HSSFRow row = sheet.getRow(rowNumber - 1);
            if (row == null) {
                continue;
            }
            if (key.equals(cellText(row.getCell(job.keyColumn - 1)))) {
                if (found >= 0) {
                    throw new IllegalStateException("duplicate key: " + key);
                }
                found = rowNumber;
            }
        }
        if (found < 0) {
            throw new IllegalStateException("key not found: " + key);
        }
        return found;
    }

    private static String cellText(HSSFCell cell) {
        if (cell == null || cell.getCellType() == CellType.BLANK) {
            return "";
        }
        if (cell.getCellType() == CellType.STRING) {
            return cell.getStringCellValue();
        }
        return new DataFormatter().formatCellValue(cell);
    }

    private static void printText(Update update, int row, int column, String current) {
        System.out.println(
            "TEXT=" + encode(update.key) + "|" + encode(update.language) + "|" +
            row + "|" + column + "|" + encode(current) + "|" + encode(update.value)
        );
    }

    private static void writePreservedContainer(File original, File changed, File output)
        throws IOException {
        Files.deleteIfExists(output.toPath());
        try (FileInputStream originalInput = new FileInputStream(original);
             POIFSFileSystem base = new POIFSFileSystem(originalInput);
             POIFSFileSystem modified = new POIFSFileSystem(changed, true)) {
            String sourceName = workbookEntryName(base);
            String changedName = workbookEntryName(modified);
            try (DocumentInputStream workbookStream =
                     modified.createDocumentInputStream(changedName)) {
                base.getRoot().createOrUpdateDocument(sourceName, workbookStream);
            }
            try (FileOutputStream stream = new FileOutputStream(output)) {
                base.writeFilesystem(stream);
            }
        }
    }

    private static String workbookEntryName(POIFSFileSystem fileSystem) {
        if (fileSystem.getRoot().hasEntry("Workbook")) {
            return "Workbook";
        }
        if (fileSystem.getRoot().hasEntry("Book")) {
            return "Book";
        }
        throw new IllegalStateException("Workbook stream not found");
    }

    private static void verifyOutput(Job job, Map<String, Integer> rowsByKey) throws IOException {
        try (POIFSFileSystem fileSystem = new POIFSFileSystem(job.output, true);
             HSSFWorkbook workbook = new HSSFWorkbook(fileSystem, true)) {
            HSSFSheet sheet = workbook.getSheetAt(0);
            if (!readActiveLanguages(sheet, job).equals(job.activeLanguages)) {
                throw new IllegalStateException("saved active languages mismatch");
            }
            for (Update update : job.updates) {
                int row = rowsByKey.get(update.key);
                int column = job.languageColumns.get(update.language);
                String saved = cellText(sheet.getRow(row - 1).getCell(column - 1));
                if (!saved.equals(update.value)) {
                    throw new IllegalStateException(
                        "saved value mismatch for " + update.key + "/" + update.language
                    );
                }
            }
        }
    }

    private static void verifyContainer(File original, File output) throws Exception {
        try (POIFSFileSystem source = new POIFSFileSystem(original, true);
             POIFSFileSystem candidate = new POIFSFileSystem(output, true)) {
            if (!Objects.equals(
                source.getRoot().getStorageClsid(),
                candidate.getRoot().getStorageClsid()
            )) {
                throw new IllegalStateException("root CLSID changed");
            }
            Map<String, String> sourceStreams = streamHashes(source);
            Map<String, String> candidateStreams = streamHashes(candidate);
            sourceStreams.remove(workbookEntryName(source));
            candidateStreams.remove(workbookEntryName(candidate));
            if (!sourceStreams.equals(candidateStreams)) {
                throw new IllegalStateException("non-Workbook OLE streams changed");
            }
        }
    }

    private static Map<String, String> streamHashes(POIFSFileSystem fileSystem) throws Exception {
        Map<String, String> result = new LinkedHashMap<>();
        collectStreams(fileSystem.getRoot(), "", result);
        return result;
    }

    private static void collectStreams(
        DirectoryEntry directory,
        String prefix,
        Map<String, String> result
    ) throws Exception {
        List<Entry> entries = new ArrayList<>();
        Iterator<Entry> iterator = directory.getEntries();
        while (iterator.hasNext()) {
            entries.add(iterator.next());
        }
        Collections.sort(entries, (left, right) -> left.getName().compareTo(right.getName()));
        for (Entry entry : entries) {
            String path = prefix.isEmpty() ? entry.getName() : prefix + "/" + entry.getName();
            if (entry.isDirectoryEntry()) {
                collectStreams((DirectoryEntry) entry, path, result);
            } else {
                DocumentEntry document = (DocumentEntry) entry;
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                try (DocumentInputStream stream = new DocumentInputStream(document)) {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = stream.read(buffer)) >= 0) {
                        if (count > 0) {
                            digest.update(buffer, 0, count);
                        }
                    }
                }
                result.put(path, document.getSize() + ":" + hex(digest.digest()));
            }
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder builder = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            builder.append(String.format("%02x", value & 0xff));
        }
        return builder.toString();
    }

    private static String encode(String value) {
        return BASE64_ENCODER.encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private static String decode(String value) {
        return new String(BASE64_DECODER.decode(value), StandardCharsets.UTF_8);
    }

    private static final class Job {
        private String version;
        private boolean apply;
        private File input;
        private File output;
        private int keyColumn;
        private int languageCodeRow;
        private int dataStartRow;
        private final Map<String, Integer> languageColumns = new LinkedHashMap<>();
        private final List<String> activeLanguages = new ArrayList<>();
        private final List<Update> updates = new ArrayList<>();

        private void validate() {
            if (!VERSION.equals(version)) {
                throw new IllegalArgumentException("unsupported job version: " + version);
            }
            if (input == null || !input.isFile()) {
                throw new IllegalArgumentException("input workbook not found");
            }
            if (apply && output == null) {
                throw new IllegalArgumentException("apply mode requires output");
            }
            if (keyColumn < 1 || languageCodeRow < 1 || dataStartRow < 1) {
                throw new IllegalArgumentException("row and column numbers are one-based");
            }
            if (languageColumns.isEmpty() || activeLanguages.isEmpty() || updates.isEmpty()) {
                throw new IllegalArgumentException("languages, active languages and updates are required");
            }
        }
    }

    private static final class Update {
        private final String key;
        private final String language;
        private final String value;

        private Update(String key, String language, String value) {
            this.key = key;
            this.language = language;
            this.value = value;
        }
    }
}
