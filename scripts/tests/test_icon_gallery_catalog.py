import json
import pathlib
import struct
import unittest
import zlib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
GALLERY_ROOT = REPO_ROOT / "docs/icon-gallery"


def decode_rgba8(data: bytes) -> tuple[int, int, list[bytes]]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")

    header = None
    compressed = bytearray()
    offset = 8
    while offset < len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        payload = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed += payload
        elif kind == b"IEND":
            break
        offset += 12 + length

    if header is None:
        raise ValueError("missing IHDR")

    width, height, bit_depth, color_type, _, _, interlace = header
    if (bit_depth, color_type, interlace) != (8, 6, 0):
        raise ValueError(
            f"expected 8-bit non-interlaced RGBA, got depth={bit_depth} color={color_type} interlace={interlace}"
        )

    raw = zlib.decompress(bytes(compressed))
    stride = width * 4
    rows: list[bytes] = []
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride
        for index in range(stride):
            left = line[index - 4] if index >= 4 else 0
            up = previous[index]
            up_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                continue
            if filter_type == 1:
                line[index] = (line[index] + left) & 0xFF
            elif filter_type == 2:
                line[index] = (line[index] + up) & 0xFF
            elif filter_type == 3:
                line[index] = (line[index] + ((left + up) >> 1)) & 0xFF
            elif filter_type == 4:
                estimate = left + up - up_left
                deltas = (abs(estimate - left), abs(estimate - up), abs(estimate - up_left))
                if deltas[0] <= deltas[1] and deltas[0] <= deltas[2]:
                    predictor = left
                elif deltas[1] <= deltas[2]:
                    predictor = up
                else:
                    predictor = up_left
                line[index] = (line[index] + predictor) & 0xFF
            else:
                raise ValueError(f"unsupported row filter {filter_type}")
        rows.append(bytes(line))
        previous = line

    return width, height, rows


class IconGalleryCatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = json.loads((GALLERY_ROOT / "catalog.json").read_text(encoding="utf-8"))

    def test_assets_declare_unique_ids_known_categories_and_rendering_modes(self) -> None:
        category_ids = [category["id"] for category in self.catalog["categories"]]
        self.assertEqual(len(category_ids), len(set(category_ids)))

        asset_ids = [asset["id"] for asset in self.catalog["assets"]]
        self.assertEqual(len(asset_ids), len(set(asset_ids)))

        problems = []
        for asset in self.catalog["assets"]:
            if asset["categoryID"] not in category_ids:
                problems.append(f"{asset['id']}: unknown category {asset['categoryID']!r}")
            if asset.get("renderingMode") not in {"template", "original"}:
                problems.append(f"{asset['id']}: renderingMode {asset.get('renderingMode')!r}")
            if asset["frameCount"] < 1 or asset["frameDuration"] <= 0:
                problems.append(f"{asset['id']}: frameCount/frameDuration out of range")
            frame_paths = asset.get("framePaths")
            if frame_paths is not None and len(frame_paths) != asset["frameCount"]:
                problems.append(f"{asset['id']}: framePaths does not match frameCount")

        self.assertEqual(problems, [])

    def test_declared_resource_paths_are_checked_in(self) -> None:
        missing = []
        for asset in self.catalog["assets"]:
            paths = list(asset.get("framePaths") or [])
            for key in ("previewPath", "archivePath"):
                if asset.get(key):
                    paths.append(asset[key])
            for path in paths:
                if not (GALLERY_ROOT / path).is_file():
                    missing.append(f"{asset['id']}: {path}")

        self.assertEqual(missing, [])

    def test_static_template_frames_use_black_transparent_artwork(self) -> None:
        # Archive assets are excluded: the imported RunCat animations predate this check and
        # keep a few near-black antialiasing pixels that AppKit still tints correctly.
        assets = [
            asset
            for asset in self.catalog["assets"]
            if asset.get("renderingMode") == "template" and asset.get("framePaths")
        ]
        self.assertTrue(assets)

        problems = []
        for asset in assets:
            for path in asset["framePaths"]:
                _, _, rows = decode_rgba8((GALLERY_ROOT / path).read_bytes())
                has_visible = False
                has_transparent = False
                for row in rows:
                    for offset in range(0, len(row), 4):
                        red, green, blue, alpha = row[offset:offset + 4]
                        if alpha <= 8:
                            has_transparent = True
                            continue
                        has_visible = True
                        peak = max(red, green, blue)
                        if peak - min(red, green, blue) > 6 or peak > max(12, int(alpha * 0.12)):
                            problems.append(f"{path}: non-black pixel rgba{(red, green, blue, alpha)}")
                            break
                    else:
                        continue
                    break
                if not has_visible:
                    problems.append(f"{path}: no visible artwork")
                if not has_transparent:
                    problems.append(f"{path}: opaque background")

        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
