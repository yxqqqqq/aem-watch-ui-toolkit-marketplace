#!/usr/bin/env python3
"""Track verified AEM Watch resource inputs and outputs outside the repo."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid
import xml.etree.ElementTree as ET


SCHEMA_VERSION = 1
IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def normalized_absolute(path: Path) -> Path:
    value = os.path.abspath(os.fspath(path))
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return Path(value)


def path_is_under(path: Path, root: Path) -> bool:
    resolved = normalized_absolute(path)
    resolved_root = normalized_absolute(root)
    common = os.path.commonpath((str(resolved), str(resolved_root)))
    return common.lower() == str(resolved_root).lower()


def ensure_under(path: Path, root: Path, label: str) -> Path:
    resolved = normalized_absolute(path)
    if not path_is_under(resolved, root):
        raise ValueError(f"{label} escapes project root: {resolved}")
    return resolved


def state_key(path: Path, project_root: Path) -> str:
    resolved = ensure_under(path, project_root, "Tracked path")
    return Path(os.path.relpath(resolved, project_root)).as_posix()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path, previous: dict | None = None, *, cache_hash: bool = False) -> dict:
    if not path.is_file():
        record = {"exists": False, "size": 0, "sha256": None}
        if cache_hash:
            record["mtimeNs"] = None
        return record
    stat = path.stat()
    digest = None
    if (
        cache_hash
        and previous
        and previous.get("exists") is True
        and previous.get("size") == stat.st_size
        and previous.get("mtimeNs") == stat.st_mtime_ns
        and previous.get("sha256")
    ):
        digest = str(previous["sha256"])
    if digest is None:
        digest = sha256_file(path)
    record = {
        "exists": True,
        "size": stat.st_size,
        "sha256": digest,
    }
    if cache_hash:
        record["mtimeNs"] = stat.st_mtime_ns
    return record


def referenced_images(ui_project: Path, resource_root: Path) -> set[Path]:
    document = ET.parse(ui_project)
    images: set[Path] = set()
    for element in document.iter():
        raw_value = element.attrib.get("value", "")
        normalized_value = raw_value.replace("\\", os.sep).replace("/", os.sep)
        candidate = normalized_absolute(ui_project.parent / normalized_value)
        if candidate.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        if path_is_under(candidate, resource_root):
            images.add(candidate)
    return images


def identity_from_job(job: dict) -> dict:
    project_root = normalized_absolute(Path(job["projectRoot"]))
    return {
        "projectRoot": str(project_root),
        "application": str(job["identity"]["application"]),
        "board": str(job["identity"]["board"]),
        "resolution": str(job["identity"]["resolution"]),
    }


def capture_inputs(job: dict, previous_inputs: dict | None = None) -> dict:
    project_root = normalized_absolute(Path(job["projectRoot"]))
    resource_root = ensure_under(
        Path(job["resourceRoot"]), project_root, "Resource root"
    )
    ui_project = ensure_under(
        Path(job["uiProject"]), project_root, "UI project"
    )
    translation_table = ensure_under(
        Path(job["translationTable"]), project_root, "Translation table"
    )
    if not ui_project.is_file():
        raise FileNotFoundError(f"UI project not found: {ui_project}")

    paths = {ui_project, translation_table}
    paths.update(referenced_images(ui_project, resource_root))
    previous_inputs = previous_inputs or {}
    inputs = {}
    for path in sorted(paths):
        key = state_key(path, project_root)
        inputs[key] = file_record(
            path,
            previous_inputs.get(key),
            cache_hash=True,
        )
    identity = identity_from_job(job)
    digest_inputs = {
        key: {
            "exists": value["exists"],
            "size": value["size"],
            "sha256": value["sha256"],
        }
        for key, value in inputs.items()
    }
    digest_payload = json.dumps(
        {"identity": identity, "inputs": digest_inputs},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "identity": identity,
        "inputs": inputs,
        "inputDigest": hashlib.sha256(digest_payload).hexdigest(),
    }


def capture_outputs(job: dict) -> dict:
    project_root = normalized_absolute(Path(job["projectRoot"]))
    return {
        state_key(Path(value), project_root): file_record(
            ensure_under(Path(value), project_root, "Generated output")
        )
        for value in sorted(job["requiredOutputs"])
    }


def state_file_path(job: dict, identity: dict) -> Path:
    state_root = normalized_absolute(Path(job["stateRoot"]))
    identity_text = "|".join(
        (
            identity["projectRoot"].lower(),
            identity["application"],
            identity["board"],
            identity["resolution"],
        )
    )
    identity_hash = hashlib.sha256(identity_text.encode("utf-8")).hexdigest()[:16]
    stem = "-".join(
        re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
        for value in (
            identity["application"],
            identity["board"],
            identity["resolution"],
        )
    )
    return state_root / f"{stem}-{identity_hash}.json"


def read_state(path: Path) -> tuple[dict | None, str | None]:
    if not path.is_file():
        return None, None
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"
    if not isinstance(value, dict) or value.get("schemaVersion") != SCHEMA_VERSION:
        return None, "unsupported or invalid state schema"
    return value, None


def changed_keys(before: dict, after: dict) -> list[str]:
    return sorted(
        key
        for key in set(before) | set(after)
        if before.get(key) != after.get(key)
    )


def status(job: dict) -> dict:
    identity = identity_from_job(job)
    state_path = state_file_path(job, identity)
    stored, state_error = read_state(state_path)
    previous_inputs = stored.get("inputs", {}) if stored else {}
    current = capture_inputs(job, previous_inputs)
    outputs = capture_outputs(job)
    reasons: list[str] = []
    changed_inputs: list[str] = []
    output_problems = sorted(
        key
        for key, value in outputs.items()
        if not value["exists"] or value["size"] <= 0
    )

    if state_error:
        reasons.append("stateInvalid")
    elif stored is None:
        reasons.append("noVerifiedState")
    else:
        if stored.get("identity") != current["identity"]:
            reasons.append("identityChanged")
        if stored.get("inputDigest") != current["inputDigest"]:
            reasons.append("inputDigestChanged")
            changed_inputs = changed_keys(
                stored.get("inputs", {}), current["inputs"]
            )
        if stored.get("outputs", {}) != outputs:
            reasons.append("outputHashChanged")
            output_problems.extend(
                changed_keys(stored.get("outputs", {}), outputs)
            )

    if output_problems:
        reasons.append("missingOrEmptyOutputs")
    reasons = list(dict.fromkeys(reasons))
    output_problems = sorted(set(output_problems))
    return {
        "status": "changed" if reasons else "current",
        "generationRequired": bool(reasons),
        "reasons": reasons,
        "changedInputs": changed_inputs,
        "outputProblems": output_problems,
        "stateError": state_error,
        "stateFile": str(state_path),
        "inputDigest": current["inputDigest"],
        "inputCount": len(current["inputs"]),
    }


def record(job: dict) -> dict:
    identity = identity_from_job(job)
    state_path = state_file_path(job, identity)
    stored, _ = read_state(state_path)
    previous_inputs = stored.get("inputs", {}) if stored else {}
    current = capture_inputs(job, previous_inputs)
    outputs = capture_outputs(job)
    primary_inputs = (
        ensure_under(Path(job["uiProject"]), Path(job["projectRoot"]), "UI project"),
        ensure_under(
            Path(job["translationTable"]),
            Path(job["projectRoot"]),
            "Translation table",
        ),
    )
    missing_primary = [str(path) for path in primary_inputs if not path.is_file()]
    if missing_primary:
        raise FileNotFoundError(
            "Required resource inputs are missing: " + ", ".join(missing_primary)
        )
    invalid_outputs = [
        key
        for key, value in outputs.items()
        if not value["exists"] or value["size"] <= 0
    ]
    if invalid_outputs:
        raise FileNotFoundError(
            "Generated outputs are missing or empty: " + ", ".join(invalid_outputs)
        )

    state_path.parent.mkdir(parents=True, exist_ok=True)
    state = {
        "schemaVersion": SCHEMA_VERSION,
        "verifiedAt": now_iso(),
        "identity": current["identity"],
        "inputDigest": current["inputDigest"],
        "inputs": current["inputs"],
        "outputs": outputs,
    }
    temporary = state_path.with_name(
        state_path.name + f".tmp-{uuid.uuid4().hex}"
    )
    try:
        temporary.write_text(
            json.dumps(state, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, state_path)
    finally:
        if temporary.exists():
            temporary.unlink()
    return {
        "status": "recorded",
        "generationRequired": False,
        "reasons": [],
        "changedInputs": [],
        "outputProblems": [],
        "stateError": None,
        "stateFile": str(state_path),
        "inputDigest": current["inputDigest"],
        "inputCount": len(current["inputs"]),
    }


def read_job(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("Job JSON must contain an object.")
    return value


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="aem-watch-resource-state-") as temp:
        project = Path(temp).resolve()
        resource = project / "resource"
        resource.mkdir()
        image = resource / "icon.png"
        image.write_bytes(b"image-one")
        ui = resource / "watch.ui"
        ui.write_text(
            '<ui-rad><picture value=".\\icon.png" /></ui-rad>',
            encoding="utf-8",
        )
        translation = project / "translations.xls"
        translation.write_bytes(b"translations")
        output = project / "watch.res"
        output.write_bytes(b"generated")
        state_root = project / "state"
        job = {
            "projectRoot": str(project),
            "resourceRoot": str(resource),
            "uiProject": str(ui),
            "translationTable": str(translation),
            "requiredOutputs": [str(output)],
            "stateRoot": str(state_root),
            "identity": {
                "application": "watch",
                "board": "board",
                "resolution": "466x466",
            },
        }

        initial = status(job)
        if initial["reasons"] != ["noVerifiedState"]:
            raise AssertionError(f"Unexpected initial state: {initial}")
        record(job)
        if status(job)["generationRequired"]:
            raise AssertionError("Recorded state was not current.")

        unreferenced = resource / "unused.png"
        unreferenced.write_bytes(b"unused")
        if status(job)["generationRequired"]:
            raise AssertionError("Unreferenced image changed the input state.")

        image.write_bytes(b"image-two")
        image_change = status(job)
        if "inputDigestChanged" not in image_change["reasons"]:
            raise AssertionError("Referenced image change was not detected.")
        image.write_bytes(b"image-one")
        if status(job)["generationRequired"]:
            raise AssertionError("Restored input did not return to current state.")

        output.write_bytes(b"different output")
        output_change = status(job)
        if "outputHashChanged" not in output_change["reasons"]:
            raise AssertionError("Generated output change was not detected.")
    print("SELF_TEST=SUCCESS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", type=Path)
    parser.add_argument("--action", choices=("status", "record"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.job is None or args.action is None:
        parser.error("--job and --action are required unless --self-test is used")
    job = read_job(args.job.resolve())
    result = status(job) if args.action == "status" else record(job)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"RESULT=FAILED", file=sys.stderr)
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
