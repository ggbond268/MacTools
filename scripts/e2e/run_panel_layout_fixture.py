#!/usr/bin/env python3
"""Run native panel drag acceptance without loading plugins or user preferences.

The fixture compiles the production editor, drag source, destination/session,
scrolling, grid packing, and editing controls with synthetic host/theme interfaces. XCTest
separately verifies real PluginHost persistence. A standalone NSApplication run
loop is required: XCTest's async event pump does not deliver native drop sessions.
Drag acceptance briefly positions the cursor inside its fixture and restores it
afterward; mouse button events remain scoped to the fixture window.
"""

from pathlib import Path
import argparse
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def extract(path, start, end=None):
    source = (ROOT / path).read_text()
    content = start + source.split(start, 1)[1]
    return content.split(end, 1)[0] if end else content


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--surface", action="append", choices=("tabs", "cross-panels", "dashboard", "features"),
                        help="Run only the selected surface; repeat to select multiple surfaces.")
    surfaces = parser.parse_args().surface or ("tabs", "cross-panels", "dashboard", "features")
    with tempfile.TemporaryDirectory(prefix="mactools-panel-layout-") as temporary:
        output = Path(temporary)
        parts = [(ROOT / "scripts/e2e/PanelLayoutInteractionFixture.swift").read_text()]
        parts.append(extract("Sources/App/ComponentPanelContent.swift",
                             "enum ComponentGridPlacementEngine {", "\nstruct ComponentPanelContent:"))
        parts.append(extract("Sources/Core/Plugins/MenuBarPanelStore.swift",
                             "struct MenuBarPanelDefinition:", "\n@MainActor\nfinal class MenuBarPanelStore"))
        parts.append(extract("Sources/App/ConfiguredMenuBarPanelContent.swift",
                             "enum ConfiguredMenuBarPanelLayout {", "    static func contentHeight(" ) + "}\n")
        parts.append(extract("Sources/App/MenuBarPanelPresenter.swift", "@MainActor\nfinal class MenuBarPanelEditingFeedback {"))
        for name in ("PanelViewportStack", "MenuBarPanelEditingTabs", "PanelLayoutEditingSession", "PanelLayoutDragScroller", "PanelLayoutHoverTracking", "PanelLayoutEditor", "PanelLayoutDragSource"):
            parts.append((ROOT / f"Sources/App/{name}.swift").read_text().replace("import MacToolsPluginKit", ""))
        source = output / "Fixture.swift"
        source.write_text("\n".join(parts))
        executable = output / "fixture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                        "-target", f"{platform.machine()}-apple-macos14.0",
                        "-default-isolation", "MainActor", "-module-cache-path", str(output / "cache"),
                        str(source), "-o", str(executable)], check=True, cwd=ROOT, timeout=120)
        if "tabs" in surfaces:
            subprocess.run([str(executable), "tabs"], check=True, cwd=ROOT, timeout=20)
        if "cross-panels" in surfaces:
            subprocess.run([str(executable), "cross-panels"], check=True, cwd=ROOT, timeout=20)
        for surface in ("dashboard", "features"):
            if surface not in surfaces:
                continue
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
