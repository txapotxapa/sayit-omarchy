"""Text cleanup, chunking and language detection (no model or audio needed)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sayitd  # noqa: E402


class CleanText(unittest.TestCase):
    def test_markdown_becomes_speakable(self):
        md = ("# Build results\n**All 42 tests** pass. See [the report](https://x.io) "
              "and `make check`.\n- first item\n- second item")
        self.assertEqual(
            sayitd.clean_text(md),
            "Build results.\nAll 42 tests pass. See the report and make check.\n"
            "first item.\nsecond item.")

    def test_tables_keep_their_rows(self):
        self.assertEqual(sayitd.clean_text("| a | b |\n|---|---|\n| 1 | 2 |"), "a, b\n\n1, 2")

    def test_code_blocks_are_not_read(self):
        self.assertIn("(code block)", sayitd.clean_text("Run:\n```\nrm -rf build\n```\nDone."))

    def test_paragraphs_survive_list_cleanup(self):
        self.assertEqual(sayitd.clean_text("Intro.\n\n- item\n\n# Next"), "Intro.\n\nitem.\n\nNext.")


class SplitChunks(unittest.TestCase):
    TEXT = ("We Must Pace the Frontier: I've written a new essay on why the AI industry "
            "should slow down, with a three-part plan for doing so. Anthropic is "
            "unilaterally committing to the first of these steps. We'll provide "
            "third-party evaluators with permanent, employee-level access to our "
            "systems, so that they can verify adherence to our safety measures, report "
            "on incidents, and assess models' alignment during training.")

    def test_no_words_lost(self):
        self.assertEqual(" ".join(sayitd.split_chunks(self.TEXT)).split(), self.TEXT.split())

    def test_chunks_grow_and_respect_caps(self):
        sizes = [len(c) for c in sayitd.split_chunks(self.TEXT)]
        self.assertLessEqual(sizes[0], 40)
        self.assertLessEqual(sizes[1], 100)
        self.assertTrue(all(s <= 280 for s in sizes))

    def test_run_on_sentences_are_split(self):
        long = "And here is a very long run-on sentence, with commas " * 12 + "that ends."
        chunks = sayitd.split_chunks(long)
        self.assertTrue(all(len(c) <= 280 for c in chunks))
        self.assertEqual(" ".join(chunks).split(), long.split())

    def test_short_text_is_one_chunk(self):
        self.assertEqual(sayitd.split_chunks("Update number 1."), ["Update number 1."])


class LooksSpanish(unittest.TestCase):
    def test_spanish(self):
        self.assertTrue(sayitd.looks_spanish("Hola, ¿cómo estás? Esto es una prueba del sistema."))
        self.assertTrue(sayitd.looks_spanish("Revisa el log de la app"))

    def test_english(self):
        self.assertFalse(sayitd.looks_spanish("The build is done and all tests pass."))
        self.assertFalse(sayitd.looks_spanish("I want to go to la playa"))


if __name__ == "__main__":
    unittest.main()
