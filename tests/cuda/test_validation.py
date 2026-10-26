"""Acceptance-tool integrity tests; no model or hardware execution is simulated as a hardware pass."""
import importlib.util
import math
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('cuda_check',Path(__file__).resolve().parents[2]/'scripts/check-cuda-reference.py')
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)

class AcceptanceTests(unittest.TestCase):
    def test_invalid_vectors_never_pass(self):
        for vector in [[0.0]*768,[1.0]*767,[math.nan]+[0.0]*767,[math.inf]+[0.0]*767]:
            with self.assertRaises(ValueError):m.checked_vector(vector)
        self.assertEqual(m.checked_vector([1.0]+[0.0]*767)[0],1.0)

    def test_cosine_uses_both_norms_and_rejects_invalid_references(self):
        self.assertAlmostEqual(m.cosine([2.0,0.0],[4.0,0.0]),1.0)
        self.assertAlmostEqual(m.cosine([2.0,0.0],[0.0,4.0]),0.0)
        for a,b in [([0.0],[1.0]),([1.0],[1.0,0.0]),([math.nan],[1.0])]:
            with self.assertRaises(ValueError):m.cosine(a,b)

    def test_cpu_vulkan_and_incomplete_receipts_are_rejected(self):
        info=dict(backend='nvidia-cuda',execution_policy='accelerator-only',precision_profile='cuda-fp32-v1',
                  build_identity='fixture',device_id='GPU-fixture',revision=m.REVISION)
        self.assertEqual(m.receipt(info),info)
        for change in [dict(backend='vulkan'),dict(backend='cpu'),dict(device_id=''),dict(precision_profile='fp16'),dict(revision='other')]:
            with self.assertRaises(ValueError):m.receipt(dict(info,**change))

if __name__=='__main__':unittest.main()
