import json
import tempfile
import unittest
from pathlib import Path

from tools.places.generate_sailing_pois import (
    build_catalogue,
    classify,
    facility_summary,
)


class SailingPoiGeneratorTest(unittest.TestCase):
    def test_classifies_marine_categories(self) -> None:
        self.assertEqual(classify({"leisure": "marina"})[0], "marina")
        self.assertEqual(classify({"industrial": "port"})[0], "harbour")
        self.assertEqual(
            classify(
                {
                    "seamark:type": "anchorage",
                    "seamark:anchorage:category": "small_craft_mooring",
                }
            )[0],
            "mooring",
        )
        self.assertEqual(classify({"leisure": "slipway"})[0], "slipway")
        self.assertEqual(classify({"seamark:type": "mooring"})[0], "mooring")
        self.assertEqual(classify({"seamark:type": "bridge"})[0], "structure")
        self.assertEqual(
            facility_summary(
                {
                    "harbour:water_tap": "yes",
                    "harbour:fuel_station": "yes",
                    "harbour:showers": "no",
                },
                "marina",
            ),
            "drinking water, fuel",
        )

    def test_builds_attributed_geojson_and_tide_stations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            osm = root / "osm.json"
            tide = root / "tides.json"
            osm.write_text(
                json.dumps(
                    {
                        "osm3s": {"timestamp_osm_base": "2026-08-20T23:30:00Z"},
                        "elements": [
                            {
                                "type": "node",
                                "id": 12,
                                "lat": 50.7,
                                "lon": -1.5,
                                "tags": {
                                    "seamark:type": "anchorage",
                                    "seamark:name": "Test anchorage",
                                },
                            }
                        ],
                    }
                )
            )
            tide.write_text(
                json.dumps(
                    {
                        "generatedFrom": {"databaseCommit": "abcdef1234567890"},
                        "source": {
                            "name": "TICON-4 via Neaps",
                            "url": "https://example.invalid/tides",
                            "licence": "CC BY 4.0",
                            "warning": "Prediction only",
                        },
                        "stations": [
                            {
                                "id": "station-1",
                                "name": "Test station",
                                "latitude": 50.8,
                                "longitude": -1.4,
                                "chartDatum": "LAT",
                            }
                        ],
                    }
                )
            )
            catalogue = build_catalogue([osm], tide)

        self.assertEqual(len(catalogue["features"]), 2)
        self.assertEqual(
            catalogue["features"][0]["properties"]["category"], "anchorage"
        )
        self.assertEqual(catalogue["features"][0]["properties"]["licence"], "ODbL 1.0")
        self.assertEqual(
            catalogue["features"][1]["properties"]["category"], "tide_station"
        )
        self.assertIn("Not an official chart", catalogue["metadata"]["warning"])


if __name__ == "__main__":
    unittest.main()
