#!/usr/bin/env python3
"""Install a verified bundle without modifying the running executable or app data."""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

project = Path(__file__).resolve().parent.parent
source = project / ".build/Harbor.app"
# HARBOR_INSTALL_ROOT is for trying the installer on a scratch folder.
applications = Path(os.environ.get("HARBOR_INSTALL_ROOT", "/Applications"))
destination = applications / "Harbor.app"
staged = applications / (".HarborSSH-install-" + str(uuid.uuid4()) + ".app")
# Validate the complete staged copy outside Documents, where File Provider can
# immediately reattach Finder metadata even after xattr clearing.
try:
    subprocess.run(["/usr/bin/ditto", "--norsrc", str(source), str(staged)], check=True)
    subprocess.run(["/usr/bin/xattr", "-cr", str(staged)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
    info = plistlib.loads((staged / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "app.harbor.ssh"
except BaseException:
    # A copy that did not verify is not left behind: it is a whole application, hidden by its name.
    shutil.rmtree(staged, ignore_errors=True)
    raise
# A Harbor that is running keeps running from the bundle that is moved aside, and the system
# names an application after its bundle: one renamed to ".HarborSSH-previous-…" asked for folder
# access under that name. So the bundle keeps its own name, inside a folder that says what it is.
holder = applications / ("Harbor previous version " + datetime.datetime.now().strftime("%Y-%m-%d %H.%M.%S"))
backup = holder / "Harbor.app"
if destination.exists():
    holder.mkdir()
    os.rename(destination, backup)
try:
    os.rename(staged, destination)
except BaseException:
    if backup.exists() and not destination.exists():
        os.rename(backup, destination)
        holder.rmdir()
    shutil.rmtree(staged, ignore_errors=True)
    raise
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
binary = destination / "Contents/MacOS/HarborSSH"
print("Installed:", destination)
print("Version:", info["CFBundleShortVersionString"])
print("SHA256:", hashlib.sha256(binary.read_bytes()).hexdigest())
assert hashlib.sha256(binary.read_bytes()).digest() == hashlib.sha256((source / "Contents/MacOS/HarborSSH").read_bytes()).digest()
if backup.exists():
    # Keep rollback available during installation, then use the normal recoverable
    # Trash so Spotlight and the Applications folders expose only the current app.
    subprocess.run(["/usr/bin/swift", "-e", "import Foundation; try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: nil)", str(holder)], check=True)
    print("Previous bundle moved to Trash:", holder.name)
shutil.rmtree(source)
print("Removed the generated build copy; rebuild to package again.")
print("Existing processes and user data were preserved.")
