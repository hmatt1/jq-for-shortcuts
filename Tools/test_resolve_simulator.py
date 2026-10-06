#!/usr/bin/env python3
"""Unit tests for resolve-simulator.py's device/runtime selection logic.

Run directly:
    python3 -m unittest discover -s Tools -p 'test_*.py'

resolve-simulator.py has a hyphen in its name, which is not a valid module
name, so it is loaded through importlib.
"""
import importlib.util
import pathlib
import unittest

_MODULE_PATH = pathlib.Path(__file__).parent / "resolve-simulator.py"
_spec = importlib.util.spec_from_file_location("resolve_simulator", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None, f"could not load spec for {_MODULE_PATH}"
resolve_simulator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(resolve_simulator)


class NewestTests(unittest.TestCase):
    def test_returns_none_for_empty_list(self):
        self.assertIsNone(resolve_simulator.newest([], key=lambda x: x))

    def test_returns_the_only_candidate(self):
        self.assertEqual(resolve_simulator.newest(["a"], key=lambda x: x), "a")

    def test_returns_the_lexically_greatest_by_key(self):
        result = resolve_simulator.newest(["b", "a", "c"], key=lambda x: x)
        self.assertEqual(result, "c")


class FindIPhoneProMaxTests(unittest.TestCase):
    def test_picks_the_newest_generation_when_multiple_are_present(self):
        devicetypes = [
            {"name": "iPhone 15 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro-Max"},
            {"name": "iPhone 16 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max"},
            {"name": "iPhone 17 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
        ]
        result = resolve_simulator.find_iphone_pro_max(devicetypes)
        self.assertEqual(result["name"], "iPhone 17 Pro Max")

    def test_prefers_the_iphone_13_pro_max_for_the_6_5_inch_size(self):
        devicetypes = [
            {"name": "iPhone 13 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max"},
            {"name": "iPhone 17 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
        ]
        result = resolve_simulator.find_iphone_pro_max(devicetypes)
        self.assertEqual(result["name"], "iPhone 13 Pro Max")

    def test_ignores_non_pro_max_iphones_and_other_families(self):
        devicetypes = [
            {"name": "iPhone SE (3rd generation)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"},
            {"name": "iPhone 17 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
            {"name": "iPad Pro 13-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"},
            {"name": "iPhone 17 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
        ]
        result = resolve_simulator.find_iphone_pro_max(devicetypes)
        self.assertEqual(result["name"], "iPhone 17 Pro Max")

    def test_returns_none_when_no_iphone_pro_max_exists(self):
        devicetypes = [{"name": "iPad Pro 13-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"}]
        self.assertIsNone(resolve_simulator.find_iphone_pro_max(devicetypes))


class FindIPadProTests(unittest.TestCase):
    def test_picks_the_newest_ipad_pro(self):
        devicetypes = [
            {"name": "iPad Pro 11-inch (M4)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4"},
            {"name": "iPad Pro 13-inch (M5, 16GB)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB"},
        ]
        result = resolve_simulator.find_ipad_pro(devicetypes)
        self.assertEqual(result["name"], "iPad Pro 13-inch (M5, 16GB)")

    def test_ignores_non_pro_ipads(self):
        devicetypes = [
            {"name": "iPad (10th generation)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation"},
            {"name": "iPad Air 13-inch (M2)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M2"},
        ]
        self.assertIsNone(resolve_simulator.find_ipad_pro(devicetypes))


class FindLatestIOSRuntimeTests(unittest.TestCase):
    def test_picks_the_highest_version_available_runtime(self):
        runtimes = [
            {"name": "iOS 26.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "isAvailable": True},
            {"name": "iOS 27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True},
        ]
        result = resolve_simulator.find_latest_ios_runtime(runtimes)
        self.assertEqual(result["name"], "iOS 27.0")

    def test_compares_versions_numerically(self):
        runtimes = [
            {"name": "iOS 27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True},
            {"name": "iOS 9.3", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-9-3", "version": "9.3", "isAvailable": True},
            {"name": "iOS 27.1", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "version": "27.1", "isAvailable": True},
        ]
        result = resolve_simulator.find_latest_ios_runtime(runtimes)
        self.assertEqual(result["name"], "iOS 27.1")

    def test_ignores_unavailable_runtimes(self):
        runtimes = [
            {"name": "iOS 27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": False},
            {"name": "iOS 26.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "isAvailable": True},
        ]
        result = resolve_simulator.find_latest_ios_runtime(runtimes)
        self.assertEqual(result["name"], "iOS 26.0")

    def test_defaults_missing_isavailable_to_true(self):
        runtimes = [{"name": "iOS 27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0"}]
        result = resolve_simulator.find_latest_ios_runtime(runtimes)
        self.assertIsNotNone(result)

    def test_ignores_non_ios_runtimes(self):
        runtimes = [{"name": "watchOS 11.0", "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "version": "11.0", "isAvailable": True}]
        self.assertIsNone(resolve_simulator.find_latest_ios_runtime(runtimes))


if __name__ == "__main__":
    unittest.main()
