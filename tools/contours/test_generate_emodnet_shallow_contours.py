import unittest

from tools.contours.generate_emodnet_shallow_contours import (
    build_geojson,
    contour_segments,
    parse_grid,
    stitch_segments,
)


class EmodnetShallowContourTest(unittest.TestCase):
    def test_parses_emodnet_text_grid(self) -> None:
        text = """Grid range: GridEnvelope2D[0..2, 0..1]
Grid to world: PARAM_MT["Affine",
  PARAMETER["elt_0_0", 0.1],
  PARAMETER["elt_0_2", -1.5],
  PARAMETER["elt_1_1", -0.1],
  PARAMETER["elt_1_2", 51.0]]
Contents:
Band 0:
0 5 10
2 7 12
"""
        grid, transform = parse_grid(text)
        self.assertEqual(grid, [[0.0, 5.0, 10.0], [2.0, 7.0, 12.0]])
        self.assertEqual(transform, (0.1, -1.5, -0.1, 51.0))

    def test_builds_attributed_model_contours(self) -> None:
        grid = [
            [0.0, 0.0, 0.0, 0.0],
            [0.0, -10.0, -10.0, 0.0],
            [0.0, -10.0, -10.0, 0.0],
            [0.0, 0.0, 0.0, 0.0],
        ]
        depth_grid = [[-value for value in row] for row in grid]
        lines = stitch_segments(contour_segments(depth_grid, 5.0))
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0][0], lines[0][-1])

        payload = build_geojson(grid, (0.01, -1.5, -0.01, 51.0), (5.0,))
        self.assertEqual(payload["metadata"]["levelsMetres"], [5.0])
        self.assertTrue(payload["features"][0]["properties"]["derived"])
        self.assertIn("not a charted sounding", payload["features"][0]["properties"]["warning"])


if __name__ == "__main__":
    unittest.main()
