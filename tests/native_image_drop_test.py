#!/usr/bin/env python3
"""Native Linux/X11 image-drop regression. Requires python-xlib and a display.

Runs a fixture-only editor script and sends real XDND protocol events to Orca's
separate native window. No provider request, real clipboard, or user file is used.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from Xlib import X, display, protocol


def project_snapshot(root):
    result = {}
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if relative.parts[0] in {".godot", ".git"} or path.is_symlink():
            continue
        if path.is_file():
            result[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def find_window(connection, title):
    def visit(window):
        try:
            if window.get_wm_name() == title:
                return window
            for child in window.query_tree().children:
                found = visit(child)
                if found:
                    return found
        except Exception:
            return None
        return None

    return visit(connection.screen().root)


def send_drop(connection, source_path, title):
    target = find_window(connection, title)
    if target is None:
        raise RuntimeError("Native attachment window not found")
    root = connection.screen().root
    source = root.create_window(0, 0, 8, 8, 0, X.CopyFromParent, X.InputOutput,
                                X.CopyFromParent, event_mask=X.PropertyChangeMask)
    atoms = {name: connection.intern_atom(name) for name in (
        "XdndEnter", "XdndPosition", "XdndDrop", "XdndStatus", "XdndFinished",
        "XdndSelection", "XdndActionCopy", "text/uri-list",
    )}
    source.set_selection_owner(atoms["XdndSelection"], X.CurrentTime)
    connection.sync()

    def client(name, words):
        target.send_event(protocol.event.ClientMessage(
            window=target.id, client_type=atoms[name], data=(32, words)),
            event_mask=0)
        connection.flush()

    client("XdndEnter", [source.id, 5 << 24, atoms["text/uri-list"], 0, 0])
    client("XdndPosition", [source.id, 0, 0, X.CurrentTime, atoms["XdndActionCopy"]])
    deadline = time.monotonic() + 8
    dropped = False
    delivered = False
    while time.monotonic() < deadline:
        if not connection.pending_events():
            time.sleep(0.01)
            continue
        event = connection.next_event()
        if event.type == X.ClientMessage and event.client_type == atoms["XdndStatus"]:
            if not dropped:
                client("XdndDrop", [source.id, 0, X.CurrentTime, 0, 0])
                dropped = True
        elif event.type == X.SelectionRequest:
            requestor = connection.create_resource_object("window", event.requestor.id)
            property_atom = event.property or event.target
            requestor.change_property(property_atom, atoms["text/uri-list"], 8,
                                      (Path(source_path).as_uri() + "\r\n").encode())
            requestor.send_event(protocol.event.SelectionNotify(
                time=event.time, requestor=requestor.id, selection=event.selection,
                target=event.target, property=property_atom), event_mask=0)
            connection.flush()
            delivered = True
        elif event.type == X.ClientMessage and event.client_type == atoms["XdndFinished"]:
            source.destroy()
            connection.flush()
            if delivered:
                return
    source.destroy()
    connection.flush()
    raise RuntimeError("Native XDND transfer did not finish")


def wait_json(path, process, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            return json.loads(path.read_text())
        if process.poll() is not None:
            break
        time.sleep(0.05)
    raise RuntimeError("Fixture did not produce " + path.name)


def main():
    root = Path(__file__).resolve().parent.parent
    godot = os.environ["GODOT_BIN"]
    before = project_snapshot(root)
    connection = display.Display()
    with tempfile.TemporaryDirectory(prefix="orca-native-drop-", dir=os.environ.get("ORCA_NATIVE_TEST_TMP_ROOT")) as tmp:
        directory = Path(tmp)
        environment = dict(os.environ, ORCA_IMAGE_DROP_TEST_DIR=tmp)
        process = subprocess.Popen([
            godot, "--editor", "--display-driver", "x11", "--path", str(root),
            "--script", "res://tests/image_attachment_window_editor_test.gd",
        ], cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True)
        try:
            ready = wait_json(directory / "ready.json", process)
            send_drop(connection, ready["source"], ready["title"])
            ready = wait_json(directory / "reject_ready.json", process)
            send_drop(connection, ready["source"], ready["title"])
            result = wait_json(directory / "result.json", process)
            output, _ = process.communicate(timeout=15)
            print(output, end="")
            if process.returncode != 0 or not result.get("success"):
                raise RuntimeError(result.get("error", "Native editor fixture failed"))
            after = project_snapshot(root)
            differences = sorted(key for key in before.keys() | after.keys()
                                 if before.get(key) != after.get(key))
            if differences:
                raise RuntimeError("Project files changed: " + ", ".join(differences))
            print("native_image_drop_test: PASS (accepted/rejected desktop drops; zero project-file changes)")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    output, _ = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    output, _ = process.communicate()
                print(output, end="")
            elif process.returncode != 0:
                output, _ = process.communicate()
                print(output, end="")
            connection.close()


if __name__ == "__main__":
    main()
