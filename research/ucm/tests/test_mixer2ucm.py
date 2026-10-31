"""Tests for mixer2ucm.py (stdlib unittest only).

Run from research/ucm with:
    python3 -m unittest discover -s tests -v
"""

import os
import re
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import mixer2ucm  # noqa: E402

UCM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAL_XML = os.path.join(
    UCM_DIR, "..", "..", "src", "device_gts28ltexx", "configs",
    "audio", "mixer_paths_0.xml")

CSET_RE = re.compile(r'^\s*cset "name=\'([^\']+)\'\s(.*)"$', re.M)


def write_xml(tmp, body):
    path = os.path.join(tmp, "mixer.xml")
    with open(path, "w") as fh:
        fh.write("<mixer>\n%s\n</mixer>\n" % body)
    return path


class ParsingTests(unittest.TestCase):
    """Nested path resolution."""

    def _model(self, tmp):
        return mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <ctl name="Base Switch" value="0"/>
  <path name="inner">
    <ctl name="Inner Volume" value="5"/>
    <ctl name="Base Switch" value="1"/>
  </path>
  <path name="outer">
    <ctl name="Outer Mux" value="X"/>
    <path name="inner"/>
    <ctl name="Inner Volume" value="9"/>
  </path>
"""))

    def test_nested_paths_resolved_in_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            seq = self._model(tmp).resolve("outer").seq
            # Document order of first occurrence, value of last assignment.
            self.assertEqual(list(seq.keys()),
                             ["Outer Mux", "Inner Volume", "Base Switch"])
            self.assertEqual(seq["Inner Volume"], "9")
            self.assertEqual(seq["Base Switch"], "1")

    def test_multi_level_nesting_visits_all_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="a">
    <path name="b"/>
  </path>
  <path name="b">
    <ctl name="Ctl B" value="2"/>
    <path name="c"/>
  </path>
  <path name="c">
    <ctl name="Ctl C" value="3"/>
  </path>
"""))
            res = model.resolve("a")
            self.assertEqual(list(res.seq.items()), [("Ctl B", "2"),
                                                     ("Ctl C", "3")])
            self.assertEqual(res.visited, ["a", "b", "c"])

    def test_unknown_path_reference_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="a"><path name="nope"/></path>
"""))
            with self.assertRaises(mixer2ucm.MixerError):
                model.resolve("a")

    def test_duplicate_path_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(mixer2ucm.MixerError):
                mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="a"><ctl name="X" value="1"/></path>
  <path name="a"><ctl name="X" value="2"/></path>
"""))


class CycleTests(unittest.TestCase):
    """Reference cycles must be detected and rejected."""

    def _assert_cycle(self, model, start):
        with self.assertRaises(mixer2ucm.MixerError) as ctx:
            model.resolve(start)
        self.assertIn("cycle", str(ctx.exception))

    def test_two_path_cycle(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="p1"><path name="p2"/></path>
  <path name="p2"><path name="p1"/></path>
"""))
            self._assert_cycle(model, "p1")

    def test_self_cycle(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="self"><path name="self"/></path>
"""))
            self._assert_cycle(model, "self")

    def test_deep_cycle(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="a"><path name="b"/></path>
  <path name="b"><path name="c"/></path>
  <path name="c"><path name="a"/></path>
"""))
            self._assert_cycle(model, "a")


class DisableSequenceTests(unittest.TestCase):
    """Reset values come from the top-level initial settings."""

    def test_reset_uses_initial_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <ctl name="HP Switch" value="0"/>
  <ctl name="Speaker Volume" value="100"/>
  <path name="p">
    <ctl name="HP Switch" value="1"/>
    <ctl name="Speaker Volume" value="42"/>
  </path>
"""))
            seq = model.resolve("p").seq
            self.assertEqual(model.format_disable(seq), [
                'cset "name=\'HP Switch\' off"',
                'cset "name=\'Speaker Volume\' 100"',
            ])

    def test_missing_initial_value_produces_todo_comment(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="p"><ctl name="Mystery Volume" value="7"/></path>
"""))
            self.assertEqual(
                model.format_disable(model.resolve("p").seq),
                ["# TODO no default for 'Mystery Volume'"])

    def test_real_xml_speaker_disable_sequence(self):
        model = mixer2ucm.MixerModel.from_xml(REAL_XML)
        # The HAL composite adds the gain path (and its volumes).
        lines = model.format_disable(model.resolve("speaker").seq)
        self.assertIn('cset "name=\'SPK Switch\' off"', lines)
        self.assertIn('cset "name=\'SPKOUT EDRE Switch\' off"', lines)
        self.assertIn("# TODO no default for 'Speaker Digital Volume'",
                      lines)


class ValueFormattingTests(unittest.TestCase):
    """Switch / enum / integer / blob formatting."""

    def test_switch_on_off(self):
        self.assertEqual(mixer2ucm.format_value("SPK Switch", "1"), "on")
        self.assertEqual(mixer2ucm.format_value("SPK Switch", "0"), "off")

    def test_enum_verbatim(self):
        self.assertEqual(mixer2ucm.format_value("SPKOUTL Input 1", "AIF1RX1"),
                         "AIF1RX1")
        self.assertEqual(mixer2ucm.format_value("AIF2 Mode", "Slave"),
                         "Slave")
        self.assertEqual(mixer2ucm.format_value("LHPF1 Mode", "High-pass"),
                         "High-pass")

    def test_integer_and_blob_verbatim(self):
        self.assertEqual(mixer2ucm.format_value("IN2 Volume", "30"), "30")
        self.assertEqual(mixer2ucm.format_value("HP1 Bias", "192 0"),
                         "192 0")
        self.assertEqual(mixer2ucm.format_value("Input Ramp Up", "8ms/6dB"),
                         "8ms/6dB")

    def test_switch_with_non_binary_value_verbatim(self):
        self.assertEqual(
            mixer2ucm.format_value("Some Switch", "High-pass"), "High-pass")

    def test_quotes_rejected(self):
        with self.assertRaises(mixer2ucm.MixerError):
            mixer2ucm.format_value("Evil", 'a"b')


class EmptyPathTests(unittest.TestCase):
    """Empty Android paths produce TODO comments, not invented controls."""

    REAL_EMPTIES = ["media-handset", "incall_nb-handset", "incall_wb-handset",
                    "incall_nb-handset-mic", "incall_wb-handset-mic",
                    "gain-media-handset", "gain-incall_nb-handset",
                    "gain-incall_wb-handset", "gain-incall_nb-handset-mic",
                    "gain-incall_wb-handset-mic", "hdmi", "hdmi-mic",
                    "speaker-and-hdmi"]

    def test_empty_path_resolution(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="todo">
    <!-- nothing here -->
  </path>
"""))
            res = model.resolve("todo")
            self.assertEqual(res.seq, {})
            self.assertEqual(res.empty_leaves, ["todo"])

    def test_device_sequence_carries_todo_comment(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = mixer2ucm.MixerModel.from_xml(write_xml(tmp, """
  <path name="empty_path"/>
  <path name="gain_empty_path"/>
"""))
            dev = dict(name="Earpiece", comment="c",
                       paths=["empty_path", "gain_empty_path"],
                       playback=True, capture=False,
                       playback_priority=1, capture_priority=None,
                       conflicts=[])
            enable = mixer2ucm._device_enable_lines(model, dev)
            self.assertEqual(enable, [
                "# TODO: empty in Android mixer_paths (path 'empty_path')",
                "# TODO: empty in Android mixer_paths "
                "(path 'gain_empty_path')",
            ])
            disable = mixer2ucm._device_disable_lines(model, dev)
            self.assertEqual(disable, enable)

    def test_real_xml_empty_paths_are_known(self):
        model = mixer2ucm.MixerModel.from_xml(REAL_XML)
        empties = [n for n in model.paths if not model.paths[n]]
        self.assertEqual(sorted(empties), sorted(self.REAL_EMPTIES))
        # The Earpiece HiFi device is exactly the empty handset paths.
        for name in ("media-handset", "gain-media-handset"):
            self.assertEqual(model.resolve(name).seq, {})


class GeneratedTreeTests(unittest.TestCase):
    """End-to-end generation against the real XML."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="mixer2ucm-test-")
        cls.model = mixer2ucm.MixerModel.from_xml(REAL_XML)
        mixer2ucm.generate(cls.model, "gts28lte", "Samsung", "wb", cls.tmp,
                           "unit test")
        base = os.path.join(cls.tmp, "ucm2", "Samsung", "gts28lte")
        cls.paths = {
            "card": os.path.join(base, "gts28lte.conf"),
            "hifi": os.path.join(base, "HiFi.conf"),
            "voice": os.path.join(base, "VoiceCall.conf"),
            "voicenb": os.path.join(base, "VoiceCallNB.conf"),
            "confd": os.path.join(cls.tmp, "ucm2", "conf.d", "gts28lte",
                                  "gts28lte.conf"),
            "report": os.path.join(cls.tmp, "REPORT.md"),
        }
        cls.files = {}
        for key, path in cls.paths.items():
            with open(path) as fh:
                cls.files[key] = fh.read()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def _device_block(self, conf, device):
        start = conf.index('SectionDevice."%s" {' % device)
        end = conf.index("\n}", start)
        return conf[start:end]

    def test_golden_speaker_hifi_cset(self):
        block = self._device_block(self.files["hifi"], "Speaker")
        self.assertIn('cset "name=\'SPKOUTL Input 1\' AIF1RX1"', block)

    def test_all_csets_come_from_the_xml(self):
        """Anti-hallucination: no cset may exist outside the XML."""
        allowed = set()
        for name, val in self.model.initial.items():
            allowed.add((name, mixer2ucm.format_value(name, val)))
        for elements in self.model.paths.values():
            for kind, a, b in elements:
                if kind == "ctl":
                    allowed.add((a, mixer2ucm.format_value(a, b)))
        for key in ("card", "hifi", "voice", "voicenb"):
            for name, val in CSET_RE.findall(self.files[key]):
                self.assertIn((name, val), allowed,
                              "%s: invented cset %r=%r" % (key, name, val))

    def test_verb_files_structure(self):
        for key in ("hifi", "voice", "voicenb"):
            text = self.files[key]
            self.assertIn("Syntax 4", text)
            self.assertIn("SectionVerb {", text)
            self.assertIn("EnableSequence [", text)
            self.assertIn("DisableSequence [", text)
        # HiFi devices exist with conflicting pairs.
        for dev in ("Speaker", "Headphones", "Earpiece", "Mic", "Headset"):
            self.assertIn('SectionDevice."%s" {' % dev, self.files["hifi"])
        for dev in ("Speaker", "Headphones", "Earpiece", "BluetoothSCO"):
            self.assertIn('SectionDevice."%s" {' % dev,
                          self.files["voice"])
        self.assertIn('PlaybackPCM "hw:${CardId},0"',
                      self._device_block(self.files["hifi"], "Speaker"))
        self.assertIn('CapturePCM "hw:${CardId},0"',
                      self._device_block(self.files["hifi"], "Mic"))
        self.assertIn("PlaybackPriority 100",
                      self._device_block(self.files["hifi"], "Speaker"))

    def test_band_split(self):
        self.assertIn("# Band: wb (wideband).", self.files["voice"])
        self.assertIn("# Band: nb (narrowband).", self.files["voicenb"])
        self.assertNotIn("# Band: wb", self.files["voicenb"])

    def test_card_conf_and_confd_stub(self):
        card = self.files["card"]
        self.assertIn('SectionUseCase."HiFi" {', card)
        self.assertIn('SectionUseCase."Voice Call" {', card)
        self.assertIn('File "/Samsung/gts28lte/HiFi.conf"', card)
        self.assertIn("BootSequence [", card)
        self.assertIn('cset "name=\'Noise Gate Switch\' off"', card)
        stub = self.files["confd"]
        self.assertIn('Include.card.File "/Samsung/gts28lte/gts28lte.conf"',
                      stub)

    def test_report_lists_empties_and_missing_defaults(self):
        report = self.files["report"]
        self.assertIn("`incall_nb-handset`", report)
        self.assertIn("EMPTY", report)
        self.assertIn("`Speaker Digital Volume`", report)
        self.assertIn("Path -> device mapping", report)
        self.assertIn("| `media-speaker` |", report)

    def test_deterministic_output(self):
        other = tempfile.mkdtemp(prefix="mixer2ucm-test2-")
        try:
            mixer2ucm.generate(self.model, "gts28lte", "Samsung", "wb", other,
                               "unit test")
            for root, _dirs, names in os.walk(self.tmp):
                for name in names:
                    path_a = os.path.join(root, name)
                    rel = os.path.relpath(path_a, self.tmp)
                    path_b = os.path.join(other, rel)
                    with open(path_a, "rb") as fa, open(path_b, "rb") as fb:
                        self.assertEqual(fa.read(), fb.read(), rel)
        finally:
            shutil.rmtree(other)

    def test_cli_main_runs(self):
        out = tempfile.mkdtemp(prefix="mixer2ucm-cli-")
        try:
            rc = mixer2ucm.main(["--xml", REAL_XML, "--card", "testcard",
                                 "--out", out, "--band", "nb"])
            self.assertEqual(rc, 0)
            base = os.path.join(out, "ucm2", "Samsung", "testcard")
            for name in ("testcard.conf", "HiFi.conf", "VoiceCall.conf",
                         "VoiceCallNB.conf"):
                self.assertTrue(os.path.isfile(os.path.join(base, name)))
            # NB selected: the NB file carries the wideband alternative.
            with open(os.path.join(base, "VoiceCallNB.conf")) as fh:
                self.assertIn("# Band: wb (wideband).", fh.read())
            self.assertTrue(os.path.isfile(
                os.path.join(out, "ucm2", "conf.d", "testcard",
                             "testcard.conf")))
        finally:
            shutil.rmtree(out)


if __name__ == "__main__":
    unittest.main()
