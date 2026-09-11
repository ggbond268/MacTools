#!/usr/bin/env python3
"""Run native panel drag acceptance without loading plugins or user preferences.

The fixture compiles the production editor, drag source, destination/session,
scrolling, grid packing, and toolbar with synthetic host/theme interfaces. XCTest
separately verifies real PluginHost persistence. A standalone NSApplication run
loop is required: XCTest's async event pump does not deliver native drop sessions.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def extract(path, start, end=None):
    source = (ROOT / path).read_text()
    content = start + source.split(start, 1)[1]
    return content.split(end, 1)[0] if end else content


def main():
    with tempfile.TemporaryDirectory(prefix="mactools-panel-layout-") as temporary:
        output = Path(temporary)
        parts = [(ROOT / "scripts/e2e/PanelLayoutInteractionFixture.swift").read_text()]
        parts.append(extract("Sources/App/ComponentPanelContent.swift",
                             "enum ComponentGridPlacementEngine {", "\nstruct ComponentPanelContent:"))
        parts.append(extract("Sources/App/MenuBarPanelPresenter.swift", "struct MenuBarPanelToolbar: View {"))
        for name in ("PanelLayoutEditingSession", "PanelLayoutDragScroller", "PanelLayoutEditor", "PanelLayoutDragSource"):
            parts.append((ROOT / f"Sources/App/{name}.swift").read_text().replace("import MacToolsPluginKit", ""))
        source = output / "Fixture.swift"
        source.write_text("\n".join(parts))
        executable = output / "fixture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                        "-default-isolation", "MainActor", "-module-cache-path", str(output / "cache"),
                        str(source), "-o", str(executable)], check=True, cwd=ROOT, timeout=120)
        for surface in ("dashboard", "features"):
            for direction in ("ltr", "rtl"):
                command = [str(executable), surface, direction]
                for attempt in range(1, 4):
                    try:
                        subprocess.run(command, check=True, cwd=ROOT, timeout=20)
                        break
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                        if attempt == 3:
                            raise
                        print(
                            f"Retrying {surface} {direction} native interaction "
                            f"after synthetic event failure ({attempt}/3)",
                            flush=True,
                        )


if __name__ == "__main__":
    main()
