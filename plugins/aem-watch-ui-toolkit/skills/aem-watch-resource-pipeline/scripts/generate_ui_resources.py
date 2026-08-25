#!/usr/bin/env python3
"""Transactionally generate AEM Watch resources through the native UI Editor GUI.

The script intentionally uses only the Python standard library and Win32 APIs.
It snapshots the configured resource roots before launching UI-Editor.exe,
drives native menus/dialogs without keyboard focus, validates the generated
files, and restores the exact snapshot if any step fails.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import datetime as dt
import difflib
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback
import uuid
import xml.etree.ElementTree as ET


if os.name != "nt":
    raise SystemExit("UI Editor automation is supported only on Windows.")


user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

WM_COMMAND = 0x0111
WM_CLOSE = 0x0010
WM_SETTEXT = 0x000C
BM_CLICK = 0x00F5
LVM_GETITEMCOUNT = 0x1004
MF_BYPOSITION = 0x0400
TH32CS_SNAPPROCESS = 0x00000002
PROCESS_TERMINATE = 0x0001
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

WNDENUMPROC = ctypes.WINFUNCTYPE(
    wintypes.BOOL, wintypes.HWND, wintypes.LPARAM
)


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", wintypes.LONG),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.WCHAR * 260),
    ]


user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL
user32.EnumChildWindows.argtypes = [
    wintypes.HWND,
    WNDENUMPROC,
    wintypes.LPARAM,
]
user32.EnumChildWindows.restype = wintypes.BOOL
user32.GetWindowThreadProcessId.argtypes = [
    wintypes.HWND,
    ctypes.POINTER(wintypes.DWORD),
]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextLengthW.restype = ctypes.c_int
user32.GetWindowTextW.argtypes = [
    wintypes.HWND,
    wintypes.LPWSTR,
    ctypes.c_int,
]
user32.GetWindowTextW.restype = ctypes.c_int
user32.GetClassNameW.argtypes = [
    wintypes.HWND,
    wintypes.LPWSTR,
    ctypes.c_int,
]
user32.GetClassNameW.restype = ctypes.c_int
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.IsWindowEnabled.argtypes = [wintypes.HWND]
user32.IsWindowEnabled.restype = wintypes.BOOL
user32.GetDlgCtrlID.argtypes = [wintypes.HWND]
user32.GetDlgCtrlID.restype = ctypes.c_int
user32.GetParent.argtypes = [wintypes.HWND]
user32.GetParent.restype = wintypes.HWND
user32.GetMenu.argtypes = [wintypes.HWND]
user32.GetMenu.restype = wintypes.HMENU
user32.GetMenuItemCount.argtypes = [wintypes.HMENU]
user32.GetMenuItemCount.restype = ctypes.c_int
user32.GetSubMenu.argtypes = [wintypes.HMENU, ctypes.c_int]
user32.GetSubMenu.restype = wintypes.HMENU
user32.GetMenuItemID.argtypes = [wintypes.HMENU, ctypes.c_int]
user32.GetMenuItemID.restype = wintypes.UINT
user32.GetMenuStringW.argtypes = [
    wintypes.HMENU,
    wintypes.UINT,
    wintypes.LPWSTR,
    ctypes.c_int,
    wintypes.UINT,
]
user32.GetMenuStringW.restype = ctypes.c_int
user32.PostMessageW.argtypes = [
    wintypes.HWND,
    wintypes.UINT,
    wintypes.WPARAM,
    wintypes.LPARAM,
]
user32.PostMessageW.restype = wintypes.BOOL
user32.SendMessageW.argtypes = [
    wintypes.HWND,
    wintypes.UINT,
    wintypes.WPARAM,
    wintypes.LPARAM,
]
user32.SendMessageW.restype = ctypes.c_ssize_t

kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.Process32FirstW.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(PROCESSENTRY32W),
]
kernel32.Process32FirstW.restype = wintypes.BOOL
kernel32.Process32NextW.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(PROCESSENTRY32W),
]
kernel32.Process32NextW.restype = wintypes.BOOL
kernel32.OpenProcess.argtypes = [
    wintypes.DWORD,
    wintypes.BOOL,
    wintypes.DWORD,
]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel32.TerminateProcess.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_absolute(path: Path) -> Path:
    value = os.path.abspath(os.fspath(path))
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return Path(value)


def ensure_under(path: Path, root: Path, label: str) -> Path:
    resolved = normalized_absolute(path)
    resolved_root = normalized_absolute(root)
    common = os.path.commonpath((str(resolved), str(resolved_root)))
    if common.lower() != str(resolved_root).lower():
        raise ValueError(f"{label} escapes project root: {resolved}")
    return resolved


def read_job(path: Path) -> dict:
    with path.open("r", encoding="utf-8-sig") as stream:
        job = json.load(stream)
    if not isinstance(job, dict):
        raise ValueError("Job JSON must contain an object.")
    return job


def window_text(hwnd: int) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(max(length + 1, 2))
    user32.GetWindowTextW(hwnd, buffer, len(buffer))
    return buffer.value


def window_class(hwnd: int) -> str:
    buffer = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buffer, len(buffer))
    return buffer.value


def window_pid(hwnd: int) -> int:
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def enum_windows() -> list[int]:
    result: list[int] = []

    @WNDENUMPROC
    def callback(hwnd: int, _: int) -> bool:
        result.append(int(hwnd))
        return True

    ctypes.set_last_error(0)
    if not user32.EnumWindows(callback, 0):
        error_code = ctypes.get_last_error()
        if error_code:
            raise ctypes.WinError(error_code)
        raise RuntimeError(
            "GUI_AUTOMATION_UNAVAILABLE: Windows window enumeration is "
            "blocked in the current execution environment. Run Generate or "
            "FinalizeResources with desktop GUI access outside the sandbox."
        )
    return result


def enum_children(hwnd: int) -> list[int]:
    result: list[int] = []

    @WNDENUMPROC
    def callback(child: int, _: int) -> bool:
        result.append(int(child))
        return True

    user32.EnumChildWindows(hwnd, callback, 0)
    return result


def process_table() -> dict[int, dict]:
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == INVALID_HANDLE_VALUE:
        raise ctypes.WinError(ctypes.get_last_error())
    table: dict[int, dict] = {}
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(entry)
        ok = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            table[int(entry.th32ProcessID)] = {
                "parent": int(entry.th32ParentProcessID),
                "name": entry.szExeFile,
            }
            ok = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return table


def descendant_pids(root_pid: int, include_root: bool = True) -> set[int]:
    table = process_table()
    descendants = {root_pid} if include_root and root_pid in table else set()
    frontier = {root_pid}
    while frontier:
        next_frontier = {
            pid
            for pid, info in table.items()
            if info["parent"] in frontier and pid not in descendants
        }
        descendants.update(next_frontier)
        frontier = next_frontier
    return descendants


def visible_process_windows(pids: set[int]) -> list[int]:
    return [
        hwnd
        for hwnd in enum_windows()
        if window_pid(hwnd) in pids and user32.IsWindowVisible(hwnd)
    ]


def describe_window(hwnd: int) -> dict:
    children = []
    for child in enum_children(hwnd):
        text = window_text(child)
        cls = window_class(child)
        control_id = user32.GetDlgCtrlID(child)
        if text or cls in {"Button", "Edit", "Static", "ComboBox"}:
            parent = int(user32.GetParent(child) or 0)
            children.append(
                {
                    "handle": child,
                    "class": cls,
                    "id": int(control_id),
                    "parentClass": window_class(parent) if parent else "",
                    "parentId": (
                        int(user32.GetDlgCtrlID(parent)) if parent else 0
                    ),
                    "text": text,
                    "visible": bool(user32.IsWindowVisible(child)),
                    "enabled": bool(user32.IsWindowEnabled(child)),
                }
            )
    return {
        "handle": hwnd,
        "pid": window_pid(hwnd),
        "class": window_class(hwnd),
        "title": window_text(hwnd),
        "visible": bool(user32.IsWindowVisible(hwnd)),
        "children": children,
    }


def window_all_text(description: dict) -> str:
    values = [description.get("title", "")]
    values.extend(child.get("text", "") for child in description["children"])
    return "\n".join(value for value in values if value).strip()


def find_main_window(pid: int, timeout: float) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        candidates = [
            hwnd
            for hwnd in visible_process_windows({pid})
            if window_class(hwnd) != "#32770"
        ]
        if candidates:
            candidates.sort(
                key=lambda hwnd: (
                    bool(user32.GetMenu(hwnd)),
                    len(window_text(hwnd)),
                ),
                reverse=True,
            )
            return candidates[0]
        time.sleep(0.25)
    raise TimeoutError("UI Editor main window did not appear.")


def menu_items(menu: int, prefix: tuple[str, ...] = ()) -> list[dict]:
    result = []
    count = user32.GetMenuItemCount(menu)
    for index in range(max(count, 0)):
        buffer = ctypes.create_unicode_buffer(512)
        user32.GetMenuStringW(
            menu, index, buffer, len(buffer), MF_BYPOSITION
        )
        label = buffer.value.replace("&", "").strip()
        submenu = user32.GetSubMenu(menu, index)
        command_id = int(user32.GetMenuItemID(menu, index))
        path = prefix + (label,)
        if submenu:
            result.extend(menu_items(submenu, path))
        elif command_id not in (0xFFFFFFFF, 0):
            result.append({"id": command_id, "path": list(path)})
    return result


def validate_menu_commands(main_window: int, commands: dict) -> list[dict]:
    menu = user32.GetMenu(main_window)
    if not menu:
        raise RuntimeError("UI Editor main window has no menu.")
    items = menu_items(menu)
    by_id = {item["id"]: item for item in items}
    missing = [
        f"{name}={command_id}"
        for name, command_id in commands.items()
        if int(command_id) not in by_id
    ]
    if missing:
        raise RuntimeError(
            "Configured UI Editor menu commands were not found: "
            + ", ".join(missing)
        )
    return [by_id[int(command_id)] for command_id in commands.values()]


def post_command(main_window: int, command_id: int) -> None:
    if not user32.PostMessageW(
        main_window, WM_COMMAND, int(command_id), 0
    ):
        raise ctypes.WinError(ctypes.get_last_error())


def wait_for_dialog(
    root_pid: int,
    exclude: set[int],
    timeout: float,
) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pids = descendant_pids(root_pid)
        dialogs = [
            hwnd
            for hwnd in visible_process_windows(pids)
            if hwnd not in exclude and window_class(hwnd) == "#32770"
        ]
        if dialogs:
            return dialogs[0]
        time.sleep(0.2)
    raise TimeoutError("Expected UI Editor dialog did not appear.")


def find_control(
    dialog: int,
    *,
    ids: tuple[int, ...] = (),
    classes: tuple[str, ...] = (),
    texts: tuple[str, ...] = (),
) -> int | None:
    lowered_texts = tuple(text.lower() for text in texts)
    candidates = enum_children(dialog)
    for child in candidates:
        control_id = int(user32.GetDlgCtrlID(child))
        cls = window_class(child)
        text = window_text(child).replace("&", "").strip().lower()
        if ids and control_id not in ids:
            continue
        if classes and cls not in classes:
            continue
        if lowered_texts and not any(item in text for item in lowered_texts):
            continue
        if user32.IsWindowVisible(child) and user32.IsWindowEnabled(child):
            return child
    return None


def open_project(
    root_pid: int,
    main_window: int,
    command_id: int,
    project_path: Path,
    diagnostics: list[dict],
) -> dict:
    existing = set(visible_process_windows(descendant_pids(root_pid)))
    post_command(main_window, command_id)
    dialog = wait_for_dialog(root_pid, existing, 15)
    description = describe_window(dialog)

    edit = find_control(dialog, ids=(1152,), classes=("Edit",))
    if edit is None:
        visible_edits = [
            child
            for child in enum_children(dialog)
            if window_class(child) == "Edit"
            and user32.IsWindowVisible(child)
            and user32.IsWindowEnabled(child)
        ]
        file_name_edits = [
            child
            for child in visible_edits
            if (
                int(user32.GetDlgCtrlID(user32.GetParent(child))) == 1148
                or window_class(user32.GetParent(child)) == "ComboBox"
            )
        ]
        if file_name_edits:
            edit = file_name_edits[-1]
        if visible_edits:
            edit = edit or visible_edits[-1]
    if edit is None:
        raise RuntimeError(
            "Could not find the file-name input in the Open dialog: "
            + window_all_text(description)
        )

    project_text = str(project_path)
    buffer = ctypes.create_unicode_buffer(project_text)
    user32.SendMessageW(
        edit, WM_SETTEXT, 0, ctypes.cast(buffer, ctypes.c_void_p).value
    )
    description_after_set = describe_window(dialog)
    description_after_set["role"] = "open-dialog-after-path"
    description_after_set["selectedEdit"] = int(edit)
    description_after_set["selectedEditText"] = window_text(edit)
    diagnostics.append(description_after_set)

    open_button = find_control(
        dialog,
        ids=(1,),
        classes=("Button",),
        texts=("打开", "open", "确定", "ok"),
    )
    if open_button is None:
        raise RuntimeError(
            "Could not find the Open button: "
            + window_all_text(description)
        )
    user32.SendMessageW(open_button, BM_CLICK, 0, 0)
    user32.SendMessageW(dialog, WM_COMMAND, 1, open_button)

    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        process_windows = visible_process_windows(descendant_pids(root_pid))
        current = set(process_windows)
        if dialog not in current:
            time.sleep(1.0)
            return description
        other_dialogs = [
            hwnd
            for hwnd in process_windows
            if hwnd != dialog and window_class(hwnd) == "#32770"
        ]
        if other_dialogs:
            other_description = describe_window(other_dialogs[0])
            other_description["role"] = "open-dialog-secondary"
            diagnostics.append(other_description)
            raise RuntimeError(
                "UI Editor displayed a secondary dialog while opening the "
                "project: " + window_all_text(other_description)
            )
        time.sleep(0.2)
    timeout_description = describe_window(dialog)
    timeout_description["role"] = "open-dialog-timeout"
    diagnostics.append(timeout_description)
    raise TimeoutError(
        "The Open dialog did not close after choosing the project: "
        + window_all_text(timeout_description)
    )


def wait_project_ready(
    process: subprocess.Popen,
    main_window: int,
    project_path: Path,
    timeout: float = 120,
    stable_seconds: float = 3,
) -> int:
    deadline = time.monotonic() + timeout
    last_count = -1
    stable_since = time.monotonic()
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                "UI Editor exited while loading the UI project."
            )
        title = window_text(main_window)
        list_counts = [
            int(user32.SendMessageW(child, LVM_GETITEMCOUNT, 0, 0))
            for child in enum_children(main_window)
            if window_class(child) == "SysListView32"
            and user32.IsWindowVisible(child)
        ]
        count = max(list_counts, default=0)
        if count != last_count:
            last_count = count
            stable_since = time.monotonic()
        title_loaded = (
            str(project_path).lower() in title.lower()
            or project_path.name.lower() in title.lower()
        )
        if (
            title_loaded
            and count > 0
            and time.monotonic() - stable_since >= stable_seconds
        ):
            return count
        time.sleep(0.5)
    raise TimeoutError(
        "UI Editor did not finish loading the project resource list. "
        f"title={window_text(main_window)!r}, itemCount={last_count}"
    )


def click_dialog_button(dialog: int, preferred_ids: tuple[int, ...]) -> bool:
    for control_id in preferred_ids:
        button = find_control(dialog, ids=(control_id,))
        if button is not None and window_class(button) == "Button":
            user32.SendMessageW(button, BM_CLICK, 0, 0)
            return True
    button = find_control(
        dialog,
        classes=("Button",),
        texts=("确定", "ok", "是", "yes", "关闭", "close"),
    )
    if button is not None:
        user32.SendMessageW(button, BM_CLICK, 0, 0)
        return True
    return False


def classify_dialog(description: dict) -> str:
    text = window_all_text(description).lower()
    error_tokens = (
        "错误",
        "失败",
        "异常",
        "无法",
        "找不到",
        "不存在",
        "error",
        "failed",
        "failure",
        "invalid",
        "not found",
        "cannot",
    )
    overwrite_tokens = (
        "覆盖",
        "替换",
        "overwrite",
        "replace",
    )
    success_tokens = (
        "成功",
        "完成",
        "success",
        "completed",
        "finished",
    )
    progress_tokens = (
        "正在",
        "请稍候",
        "处理中",
        "生成资源",
        "progress",
        "generating",
        "processing",
        "please wait",
    )
    if any(token in text for token in error_tokens):
        return "error"
    if any(token in text for token in overwrite_tokens):
        return "overwrite"
    if any(token in text for token in success_tokens):
        return "success"
    if any(token in text for token in progress_tokens):
        return "progress"
    return "unknown"


def iter_root_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        files.extend(path for path in root.rglob("*") if path.is_file())
    return files


def state_key(path: Path, project_root: Path) -> str:
    resolved = normalized_absolute(path)
    root = normalized_absolute(project_root)
    common = os.path.commonpath((str(resolved), str(root)))
    if common.lower() != str(root).lower():
        raise ValueError(f"Tracked path escapes project root: {resolved}")
    return Path(os.path.relpath(resolved, root)).as_posix()


def path_is_under(path: Path, root: Path) -> bool:
    resolved = normalized_absolute(path)
    resolved_root = normalized_absolute(root)
    common = os.path.commonpath((str(resolved), str(resolved_root)))
    return common.lower() == str(resolved_root).lower()


def discover_editor_temporary_files(
    ui_project: Path,
    project_root: Path,
    roots: list[Path],
    policy: dict,
) -> list[Path]:
    if not bool(policy.get("restoreUnreferencedJpegSiblings", False)):
        return []

    referenced_images: set[Path] = set()
    document = ET.parse(ui_project)
    for element in document.iter():
        raw_value = element.attrib.get("value", "")
        normalized_value = raw_value.replace("\\", os.sep).replace("/", os.sep)
        candidate = normalized_absolute(ui_project.parent / normalized_value)
        if candidate.suffix.lower() not in {".jpg", ".jpeg"}:
            continue
        if not any(path_is_under(candidate, root) for root in roots):
            continue
        referenced_images.add(candidate)

    referenced_keys = {
        state_key(path, project_root).lower()
        for path in referenced_images
    }
    temporary_files: set[Path] = set()
    for source in referenced_images:
        if not source.is_file() or source.stem.lower().endswith("_tmp"):
            continue
        temporary = source.with_name(
            source.stem + "_tmp" + source.suffix
        )
        temporary_key = state_key(temporary, project_root)
        if temporary_key.lower() in referenced_keys:
            continue
        temporary_files.add(temporary)
    return sorted(temporary_files)


def collect_metadata(
    project_root: Path,
    roots: list[Path],
    files: list[Path],
) -> dict[str, dict]:
    paths = set(iter_root_files(roots))
    paths.update(path for path in files if path.exists() and path.is_file())
    result: dict[str, dict] = {}
    for path in sorted(paths):
        try:
            stat = path.stat()
        except FileNotFoundError:
            continue
        result[state_key(path, project_root)] = {
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        }
    return result


def collect_hashed_state(
    project_root: Path,
    roots: list[Path],
    files: list[Path],
) -> dict[str, dict]:
    metadata = collect_metadata(project_root, roots, files)
    vanished = []
    for relative, item in metadata.items():
        try:
            item["sha256"] = sha256_file(project_root / relative)
        except FileNotFoundError:
            vanished.append(relative)
    for relative in vanished:
        metadata.pop(relative, None)
    return metadata


def diff_state(before: dict, after: dict) -> dict[str, list[str]]:
    before_keys = set(before)
    after_keys = set(after)
    added = sorted(after_keys - before_keys)
    deleted = sorted(before_keys - after_keys)
    modified = sorted(
        key
        for key in before_keys & after_keys
        if before[key].get("sha256") != after[key].get("sha256")
    )
    return {"added": added, "modified": modified, "deleted": deleted}


class Snapshot:
    def __init__(
        self,
        project_root: Path,
        roots: list[Path],
        files: list[Path],
        backup_dir: Path,
    ) -> None:
        self.project_root = project_root
        self.roots = roots
        self.files = files
        self.backup_dir = backup_dir
        self.before: dict[str, dict] = {}

    def create(self) -> dict[str, dict]:
        self.backup_dir.mkdir(parents=True, exist_ok=False)
        self.before = collect_hashed_state(
            self.project_root, self.roots, self.files
        )
        for relative in self.before:
            source = self.project_root / relative
            destination = self.backup_dir / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        return self.before

    def restore_keys(self, keys: set[str] | None = None) -> None:
        current = collect_metadata(
            self.project_root, self.roots, self.files
        )
        restore_set = set(self.before) if keys is None else set(keys)
        if keys is None:
            for relative in sorted(set(current) - set(self.before), reverse=True):
                target = ensure_under(
                    self.project_root / relative,
                    self.project_root,
                    "Rollback target",
                )
                target.unlink()
        else:
            for relative in sorted(keys):
                if relative not in self.before:
                    target = ensure_under(
                        self.project_root / relative,
                        self.project_root,
                        "Rollback target",
                    )
                    if target.exists() and target.is_file():
                        target.unlink()

        for relative in sorted(restore_set & set(self.before)):
            source = self.backup_dir / relative
            destination = ensure_under(
                self.project_root / relative,
                self.project_root,
                "Restore target",
            )
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

        if keys is None:
            for root in self.roots:
                for directory in sorted(
                    (path for path in root.rglob("*") if path.is_dir()),
                    key=lambda path: len(path.parts),
                    reverse=True,
                ):
                    try:
                        directory.rmdir()
                    except OSError:
                        pass

    def verify_restored(self) -> None:
        current = collect_hashed_state(
            self.project_root, self.roots, self.files
        )
        difference = diff_state(self.before, current)
        if any(difference.values()):
            raise RuntimeError(
                "Rollback verification failed: "
                + json.dumps(difference, ensure_ascii=False)
            )


def terminate_process_tree(root_pid: int) -> None:
    try:
        pids = descendant_pids(root_pid)
    except Exception:
        pids = {root_pid}
    for pid in sorted(pids, reverse=True):
        handle = kernel32.OpenProcess(PROCESS_TERMINATE, False, pid)
        if handle:
            try:
                kernel32.TerminateProcess(handle, 1)
            finally:
                kernel32.CloseHandle(handle)


def close_editor(process: subprocess.Popen, main_window: int | None) -> None:
    if process.poll() is not None:
        return
    if main_window:
        user32.PostMessageW(main_window, WM_CLOSE, 0, 0)
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass

    dialogs = [
        hwnd
        for hwnd in visible_process_windows(descendant_pids(process.pid))
        if window_class(hwnd) == "#32770"
    ]
    for dialog in dialogs:
        description = describe_window(dialog)
        text = window_all_text(description).lower()
        if any(token in text for token in ("保存", "save")):
            if not click_dialog_button(dialog, (7, 2)):
                user32.PostMessageW(dialog, WM_CLOSE, 0, 0)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        terminate_process_tree(process.pid)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass


def matches_any(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def normalize_changed_whitespace(
    *,
    project_root: Path,
    backup_dir: Path,
    files: list[Path],
) -> list[str]:
    normalized = []
    for target in files:
        if not target.is_file():
            continue
        relative = state_key(target, project_root)
        backup = backup_dir / relative
        baseline = backup.read_bytes() if backup.is_file() else b""
        current = target.read_bytes()
        baseline_bodies = [
            baseline_line.rstrip(b"\r\n")
            for baseline_line in baseline.splitlines(keepends=True)
        ]
        current_lines = []
        for line in current.splitlines(keepends=True):
            if line.endswith(b"\r\n"):
                current_lines.append((line[:-2], b"\r\n"))
            elif line.endswith(b"\n") or line.endswith(b"\r"):
                current_lines.append((line[:-1], line[-1:]))
            else:
                current_lines.append((line, b""))

        baseline_content = [body.strip(b" \t") for body in baseline_bodies]
        current_content = [body.strip(b" \t") for body, _ in current_lines]
        baseline_format_by_current_line = {}
        matcher = difflib.SequenceMatcher(
            None,
            baseline_content,
            current_content,
            autojunk=True,
        )
        for block in matcher.get_matching_blocks():
            for offset in range(block.size):
                baseline_format_by_current_line[block.b + offset] = (
                    baseline_bodies[block.a + offset]
                )

        output = bytearray()
        changed = False
        for line_index, (body, ending) in enumerate(current_lines):
            if line_index in baseline_format_by_current_line:
                updated_body = baseline_format_by_current_line[line_index]
            else:
                updated_body = body.rstrip(b" \t")
                indent_end = 0
                while (
                    indent_end < len(updated_body)
                    and updated_body[indent_end] in (0x20, 0x09)
                ):
                    indent_end += 1
                indentation = updated_body[:indent_end]
                while b" \t" in indentation:
                    indentation = indentation.replace(b" \t", b"\t")
                updated_body = indentation + updated_body[indent_end:]
            if updated_body != body:
                changed = True
            output.extend(updated_body)
            output.extend(ending)

        if changed:
            target.write_bytes(bytes(output))
            normalized.append(relative)
    return normalized


def merge_preserved_suffixes(
    *,
    project_root: Path,
    backup_dir: Path,
    specifications: list[dict],
) -> list[dict]:
    merged_items = []
    for specification in specifications:
        target = ensure_under(
            Path(specification["path"]),
            project_root,
            "Preserved suffix file",
        )
        marker_text = str(specification.get("marker", ""))
        if not marker_text:
            raise ValueError("Preserved suffix marker cannot be empty.")
        marker = marker_text.encode("utf-8")
        relative = state_key(target, project_root)
        baseline_path = backup_dir / relative
        if not baseline_path.is_file():
            raise FileNotFoundError(
                f"Preserved suffix baseline is missing: {baseline_path}"
            )
        if not target.is_file():
            raise FileNotFoundError(
                f"Generated suffix target is missing: {target}"
            )

        baseline = baseline_path.read_bytes()
        generated = target.read_bytes()
        baseline_marker_count = baseline.count(marker)
        if baseline_marker_count != 1:
            raise RuntimeError(
                f"Preserved suffix marker must occur exactly once in "
                f"baseline: {relative}: {marker_text}; "
                f"count={baseline_marker_count}"
            )
        baseline_index = baseline.find(marker)
        generated_marker_count = generated.count(marker)
        if generated_marker_count > 1:
            raise RuntimeError(
                f"Preserved suffix marker occurs more than once in generated "
                f"file: {relative}: {marker_text}; "
                f"count={generated_marker_count}"
            )
        generated_index = generated.find(marker)
        prefix = (
            generated[:generated_index]
            if generated_index >= 0
            else generated
        )
        newline = b"\r\n" if b"\r\n" in prefix else b"\n"
        merged = (
            prefix.rstrip(b"\r\n")
            + newline
            + newline
            + baseline[baseline_index:].lstrip(b"\r\n")
        )
        changed = merged != generated
        if changed:
            target.write_bytes(merged)
        merged_items.append(
            {
                "path": relative,
                "marker": marker_text,
                "action": "merged" if changed else "unchanged",
            }
        )
    return merged_items


def wait_for_generation(
    *,
    process: subprocess.Popen,
    main_window: int,
    project_root: Path,
    roots: list[Path],
    standalone_files: list[Path],
    baseline: dict[str, dict],
    activity_baseline: dict[str, dict],
    required_outputs: list[Path],
    allowed_patterns: list[str],
    ephemeral_keys: set[str],
    timeout_seconds: float,
    stable_seconds: float,
    idle_failure_seconds: float,
    allow_unchanged: bool,
    diagnostics: list[dict],
) -> tuple[dict[str, dict], dict[str, list[str]]]:
    started = time.monotonic()
    deadline = started + timeout_seconds
    last_signature: dict | None = None
    stable_since = started
    dialog_first_seen: dict[int, float] = {}
    saw_activity = False
    success_signal = False

    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"UI Editor exited during generation with code {process.returncode}."
            )

        root_pids = descendant_pids(process.pid)
        dialogs = [
            hwnd
            for hwnd in visible_process_windows(root_pids)
            if hwnd != main_window and window_class(hwnd) == "#32770"
        ]
        for dialog in dialogs:
            description = describe_window(dialog)
            kind = classify_dialog(description)
            description["classification"] = kind
            if not diagnostics or diagnostics[-1] != description:
                diagnostics.append(description)
            dialog_first_seen.setdefault(dialog, time.monotonic())
            if kind == "error":
                raise RuntimeError(
                    "UI Editor reported an error: "
                    + window_all_text(description)
                )
            if kind == "overwrite":
                if not click_dialog_button(dialog, (6, 1)):
                    raise RuntimeError(
                        "Could not accept the overwrite dialog: "
                        + window_all_text(description)
                    )
                saw_activity = True
                continue
            if kind == "success":
                if not click_dialog_button(dialog, (1, 6)):
                    raise RuntimeError(
                        "Could not close the success dialog: "
                        + window_all_text(description)
                    )
                success_signal = True
                saw_activity = True
                continue
            if kind == "progress":
                saw_activity = True
                continue
            if time.monotonic() - dialog_first_seen[dialog] > 3:
                raise RuntimeError(
                    "UI Editor displayed an unknown modal dialog: "
                    + window_all_text(description)
                )

        current_metadata = collect_metadata(
            project_root, roots, standalone_files
        )
        if current_metadata != last_signature:
            last_signature = current_metadata
            stable_since = time.monotonic()

        if current_metadata != activity_baseline:
            saw_activity = True

        child_pids = root_pids - {process.pid}
        all_required_exist = all(
            path.exists() and path.is_file() and path.stat().st_size > 0
            for path in required_outputs
        )
        stable = time.monotonic() - stable_since >= stable_seconds
        elapsed = time.monotonic() - started
        no_modal = not dialogs

        if (
            all_required_exist
            and stable
            and no_modal
            and not child_pids
            and elapsed >= 5
            and (saw_activity or success_signal or allow_unchanged)
        ):
            after = collect_hashed_state(
                project_root, roots, standalone_files
            )
            difference = diff_state(baseline, after)
            formal_changes = [
                key
                for category in ("added", "modified", "deleted")
                for key in difference[category]
                if key not in ephemeral_keys
            ]
            required_output_keys = {
                state_key(path, project_root) for path in required_outputs
            }
            output_changes = [
                key for key in formal_changes if key in required_output_keys
            ]
            if not output_changes and not allow_unchanged:
                raise RuntimeError(
                    "UI Editor completed without changing a required output."
                )
            unexpected = [
                key
                for key in formal_changes
                if not matches_any(key, allowed_patterns)
            ]
            if unexpected:
                raise RuntimeError(
                    "UI Editor changed files outside the allowlist: "
                    + ", ".join(unexpected)
                )
            formal_deleted = [
                key
                for key in difference["deleted"]
                if key not in ephemeral_keys
            ]
            if formal_deleted:
                raise RuntimeError(
                    "UI Editor deleted tracked files: "
                    + ", ".join(formal_deleted)
                )
            return after, difference

        if (
            elapsed >= idle_failure_seconds
            and not saw_activity
            and not dialogs
            and not child_pids
        ):
            raise TimeoutError(
                "UI Editor showed no generation activity and changed no files."
            )
        time.sleep(0.5)

    raise TimeoutError(
        f"UI Editor generation exceeded {timeout_seconds:.0f} seconds."
    )


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="aem-watch-ui-transaction-") as temp:
        project = Path(temp).resolve()
        root = project / "resources"
        root.mkdir()
        existing = root / "existing.txt"
        existing.write_text("before", encoding="utf-8")
        generated = root / "generated.h"
        generated.write_bytes(b"\t\tstable\r\nold trailing \r\n")
        suffix_file = root / "res_include.h"
        suffix_file.write_bytes(
            b"old image declarations\n\ntypedef enum{\nOLD_ID,\n} ids;\n#endif\n"
        )
        preserved = root / "input.ui"
        preserved.write_text("original", encoding="utf-8")
        animation = root / "animation"
        animation.mkdir()
        frame = animation / "frame.jpg"
        frame.write_bytes(b"source")
        existing_temp = animation / "frame_tmp.jpg"
        existing_temp.write_bytes(b"original temp")
        new_frame = animation / "new.jpg"
        new_frame.write_bytes(b"new source")
        referenced_temp = animation / "formal_tmp.jpg"
        referenced_temp.write_bytes(b"formal resource")
        ui_project = root / "project.ui"
        ui_project.write_text(
            "<ui-rad><picture value=\".\\animation\\frame.jpg\" />"
            "<picture value=\".\\animation\\new.jpg\" />"
            "<picture value=\".\\animation\\formal_tmp.jpg\" />"
            "</ui-rad>",
            encoding="utf-8",
        )
        discovered = discover_editor_temporary_files(
            ui_project,
            project,
            [root],
            {"restoreUnreferencedJpegSiblings": True},
        )
        expected = {
            existing_temp,
            animation / "new_tmp.jpg",
        }
        if set(discovered) != expected:
            raise AssertionError(
                f"Unexpected editor temporary candidates: {discovered}"
            )
        missing = root / "new.txt"
        backup = project / "backup"
        snapshot = Snapshot(project, [root], [], backup)
        snapshot.create()
        suffix_file.write_bytes(b"new image declarations\n")
        suffix_result = merge_preserved_suffixes(
            project_root=project,
            backup_dir=backup,
            specifications=[
                {"path": suffix_file, "marker": "typedef enum{"}
            ],
        )
        if suffix_file.read_bytes() != (
            b"new image declarations\n\ntypedef enum{\n"
            b"OLD_ID,\n} ids;\n#endif\n"
        ):
            raise AssertionError("Generated suffix was not preserved.")
        if suffix_result[0]["action"] != "merged":
            raise AssertionError("Preserved suffix merge was not reported.")
        existing_temp.write_bytes(b"rewritten temp")
        new_temp = animation / "new_tmp.jpg"
        new_temp.write_bytes(b"new temp")
        snapshot.restore_keys(
            {state_key(path, project) for path in discovered}
        )
        if existing_temp.read_bytes() != b"original temp":
            raise AssertionError("Existing editor temp was not restored.")
        if new_temp.exists():
            raise AssertionError("New editor temp was not removed.")
        existing.write_text("after", encoding="utf-8")
        generated.write_bytes(
            b" \tstable \r\nold trailing \r\n \t\tnew trailing \t \r\n"
        )
        normalized = normalize_changed_whitespace(
            project_root=project,
            backup_dir=backup,
            files=[generated],
        )
        if generated.read_bytes() != (
            b"\t\tstable\r\nold trailing \r\n\t\tnew trailing\r\n"
        ):
            raise AssertionError(
                "Changed-line whitespace normalization was not selective."
            )
        if state_key(generated, project) not in normalized:
            raise AssertionError("Normalized file was not reported.")
        preserved.write_text("editor rewrite", encoding="utf-8")
        snapshot.restore_keys({state_key(preserved, project)})
        if preserved.read_text(encoding="utf-8") != "original":
            raise AssertionError("Preserved input file was not restored.")
        missing.write_text("new", encoding="utf-8")
        snapshot.restore_keys()
        snapshot.verify_restored()
        if existing.read_text(encoding="utf-8") != "before":
            raise AssertionError("Existing file was not restored.")
        if missing.exists():
            raise AssertionError("New file was not removed.")
    print("SELF_TEST=SUCCESS")


def run(job: dict) -> dict:
    project_root = normalized_absolute(Path(job["projectRoot"]))
    editor = normalized_absolute(Path(job["editor"]))
    ui_project = ensure_under(
        Path(job["uiProject"]), project_root, "UI project"
    )
    if not editor.is_file():
        raise FileNotFoundError(f"UI Editor not found: {editor}")
    if not ui_project.is_file():
        raise FileNotFoundError(f"UI project not found: {ui_project}")

    roots = [
        ensure_under(Path(value), project_root, "Snapshot root")
        for value in job["snapshotRoots"]
    ]
    for root in roots:
        if not root.is_dir():
            raise FileNotFoundError(f"Snapshot root not found: {root}")

    standalone_files = [
        ensure_under(Path(value), project_root, "Snapshot file")
        for value in job.get("snapshotFiles", [])
    ]
    required_outputs = [
        ensure_under(Path(value), project_root, "Required output")
        for value in job["requiredOutputs"]
    ]
    ephemeral_files = [
        ensure_under(Path(value), project_root, "Ephemeral file")
        for value in job.get("ephemeralFiles", [])
    ]
    editor_temporary_files = discover_editor_temporary_files(
        ui_project,
        project_root,
        roots,
        job.get("editorTemporaryFiles", {}),
    )
    configured_ephemeral_keys = {
        state_key(path, project_root) for path in ephemeral_files
    }
    editor_temporary_keys = {
        state_key(path, project_root) for path in editor_temporary_files
    }
    ephemeral_keys = configured_ephemeral_keys | editor_temporary_keys
    preserve_input_files = [
        ensure_under(Path(value), project_root, "Preserved input file")
        for value in job.get("preserveInputFiles", [])
    ]
    normalize_changed_text_files = [
        ensure_under(Path(value), project_root, "Normalization file")
        for value in job.get("normalizeChangedTextFiles", [])
    ]
    preserve_generated_suffixes = [
        {
            "path": ensure_under(
                Path(value["path"]),
                project_root,
                "Preserved suffix file",
            ),
            "marker": str(value.get("marker", "")),
        }
        for value in job.get("preserveGeneratedSuffixes", [])
    ]
    allow_missing_before = bool(job.get("allowMissingBefore", False))
    allow_unchanged = bool(job.get("allowUnchanged", False))
    missing_before = [path for path in required_outputs if not path.is_file()]
    if missing_before and not allow_missing_before:
        raise FileNotFoundError(
            "Required generated files are missing before generation: "
            + ", ".join(str(path) for path in missing_before)
            + ". Use recovery mode only when intentionally recreating them."
        )

    # Fail before creating a snapshot or launching UI Editor when the host
    # isolates desktop APIs. Codex GUI actions must be rerun with the host's
    # explicit sandbox/desktop approval instead of being retried in place.
    enum_windows()

    diagnostic_root = normalized_absolute(Path(job["diagnosticRoot"]))
    run_dir = diagnostic_root / (
        dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        + "-"
        + uuid.uuid4().hex[:8]
    )
    run_dir.mkdir(parents=True, exist_ok=False)
    backup_dir = run_dir / "backup"
    result_path = run_dir / "result.json"
    snapshot = Snapshot(
        project_root, roots, standalone_files, backup_dir
    )
    baseline = snapshot.create()
    commands = {
        name: int(value)
        for name, value in job["commands"].items()
    }
    allowed_patterns = [
        str(value).replace("\\", "/")
        for value in job["allowedChangePatterns"]
    ]
    diagnostics: list[dict] = []
    process: subprocess.Popen | None = None
    main_window: int | None = None
    result = {
        "startedAt": now_iso(),
        "status": "running",
        "projectRoot": str(project_root),
        "uiProject": str(ui_project),
        "editor": str(editor),
        "runDirectory": str(run_dir),
        "missingBefore": [
            state_key(path, project_root) for path in missing_before
        ],
        "menuCommands": [],
        "dialogs": diagnostics,
        "changes": {"added": [], "modified": [], "deleted": []},
        "editorTemporaryFiles": [],
        "preservedSuffixes": [],
        "rollbackVerified": False,
    }

    try:
        process = subprocess.Popen(
            [str(editor)],
            cwd=str(editor.parent),
            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
        )
        main_window = find_main_window(process.pid, 30)
        result["mainWindow"] = describe_window(main_window)
        result["menuCommands"] = validate_menu_commands(
            main_window, commands
        )
        open_project(
            process.pid,
            main_window,
            commands["open"],
            ui_project,
            diagnostics,
        )
        ready_count = wait_project_ready(
            process, main_window, ui_project
        )
        result["projectReadyListCount"] = ready_count
        post_command(main_window, commands["save"])
        time.sleep(2.0)
        activity_baseline = collect_metadata(
            project_root, roots, standalone_files
        )
        post_command(main_window, commands["generateQualityHigh"])

        after, difference = wait_for_generation(
            process=process,
            main_window=main_window,
            project_root=project_root,
            roots=roots,
            standalone_files=standalone_files,
            baseline=baseline,
            activity_baseline=activity_baseline,
            required_outputs=required_outputs,
            allowed_patterns=allowed_patterns,
            ephemeral_keys=ephemeral_keys,
            timeout_seconds=float(job.get("timeoutSeconds", 300)),
            stable_seconds=float(job.get("stableSeconds", 5)),
            idle_failure_seconds=float(job.get("idleFailureSeconds", 45)),
            allow_unchanged=allow_unchanged,
            diagnostics=diagnostics,
        )

        close_editor(process, main_window)
        process = None
        result["preservedSuffixes"] = merge_preserved_suffixes(
            project_root=project_root,
            backup_dir=backup_dir,
            specifications=preserve_generated_suffixes,
        )
        post_close_state = collect_hashed_state(
            project_root, roots, standalone_files
        )
        post_close_difference = diff_state(baseline, post_close_state)
        changed_after_close = {
            key
            for category in ("added", "modified", "deleted")
            for key in post_close_difference[category]
        }
        changed_editor_temporary_keys = (
            editor_temporary_keys & changed_after_close
        )
        result["editorTemporaryFiles"] = [
            {
                "path": key,
                "action": "restored" if key in baseline else "removed",
                "baselineSha256": baseline.get(key, {}).get("sha256"),
            }
            for key in sorted(changed_editor_temporary_keys)
        ]
        result["normalizedFiles"] = normalize_changed_whitespace(
            project_root=project_root,
            backup_dir=backup_dir,
            files=normalize_changed_text_files,
        )
        restore_after_generation_keys = set(configured_ephemeral_keys)
        restore_after_generation_keys.update(changed_editor_temporary_keys)
        restore_after_generation_keys.update(
            state_key(path, project_root) for path in preserve_input_files
        )
        result["restoredAfterGeneration"] = sorted(
            restore_after_generation_keys
        )
        snapshot.restore_keys(restore_after_generation_keys)
        final_state = collect_hashed_state(
            project_root, roots, standalone_files
        )
        final_difference = diff_state(baseline, final_state)
        final_formal_changes = [
            key
            for category in ("added", "modified", "deleted")
            for key in final_difference[category]
            if key not in restore_after_generation_keys
        ]
        unexpected_final = [
            key
            for key in final_formal_changes
            if not matches_any(key, allowed_patterns)
        ]
        if unexpected_final:
            raise RuntimeError(
                "UI Editor changed files outside the allowlist while closing: "
                + ", ".join(unexpected_final)
            )
        if final_difference["deleted"]:
            raise RuntimeError(
                "Tracked files are missing after generation: "
                + ", ".join(final_difference["deleted"])
            )
        for path in required_outputs:
            if not path.is_file() or path.stat().st_size <= 0:
                raise RuntimeError(
                    f"Required output is missing or empty: {path}"
                )

        result["status"] = "success"
        result["completedAt"] = now_iso()
        result["changes"] = final_difference
        result["generatedHashes"] = {
            state_key(path, project_root): final_state[
                state_key(path, project_root)
            ]["sha256"]
            for path in required_outputs
        }
        result_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        if not bool(job.get("keepBackupOnSuccess", False)):
            shutil.rmtree(backup_dir)
        return result
    except Exception as exc:
        if process is not None:
            close_editor(process, main_window)
        rollback_error = None
        try:
            snapshot.restore_keys()
            snapshot.verify_restored()
            result["rollbackVerified"] = True
        except Exception as restore_exc:
            rollback_error = restore_exc
        result["status"] = "failed"
        result["completedAt"] = now_iso()
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["traceback"] = traceback.format_exc()
        if rollback_error is not None:
            result["rollbackError"] = (
                f"{type(rollback_error).__name__}: {rollback_error}"
            )
        result_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        if rollback_error is not None:
            raise RuntimeError(
                f"{exc}; rollback also failed: {rollback_error}"
            ) from exc
        raise RuntimeError(
            f"{exc}; rollback verified. Diagnostics: {result_path}"
        ) from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.job is None:
        parser.error("--job is required unless --self-test is used")

    result = run(read_job(args.job.resolve()))
    print(f"RESULT={result['status'].upper()}")
    print(f"RUN_DIRECTORY={result['runDirectory']}")
    for category in ("added", "modified", "deleted"):
        for path in result["changes"][category]:
            print(f"{category.upper()}={path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"RESULT=FAILED", file=sys.stderr)
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
