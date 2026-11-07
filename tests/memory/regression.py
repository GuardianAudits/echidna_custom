#!/usr/bin/env python3
"""Exercise production compilation import, coverage, and fuzzing with real compiler fixtures."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("memory-results"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    solidity = Path(__file__).resolve().parents[1] / "solidity"
    fixtures = solidity / "coverage/immutables"
    cases = [(variant, limit) for variant in ("solar-none", "solc-none", "solar-stored-ipfs")
             for limit in (10000, 100000)]
    cases += [("solar-ipfs", 100000), ("solar-ipfs", 1000000)]
    results = []
    for variant, limit in cases:
        with tempfile.TemporaryDirectory(prefix="echidna-memory-") as temporary:
            directory = Path(temporary)
            project = fixtures / variant
            export = json.loads((project / "export/combined_solc.json").read_text())
            # Each case has its own export directory; source paths still refer
            # to the checked-in source used to produce the compiler fixture.
            export["sourceList"] = [str(solidity / p) for p in export["sourceList"]]
            export["sources"] = {str(solidity / p): data for p, data in export["sources"].items()}
            export["contracts"] = {
                str(solidity / key.rsplit(":", 1)[0]) + ":" + key.rsplit(":", 1)[1]: data
                for key, data in export["contracts"].items()
            }
            prepared = directory / "export.json"
            prepared.write_text(json.dumps(export))
            shim = directory / "crytic-compile"
            shim.write_text(
                "#!/usr/bin/env python3\nimport os, pathlib, shutil\n"
                "pathlib.Path('crytic-export').mkdir(exist_ok=True)\n"
                "shutil.copyfile(os.environ['MEMORY_EXPORT'], 'crytic-export/combined_solc.json')\n"
            )
            shim.chmod(0o755)
            config = directory / "config.yaml"
            config.write_text(
                'cryticArgs: ["--foundry-out-directory", "out"]\ncoverageFormats: []\n'
            )
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       MEMORY_EXPORT=str(prepared))
            command = [str(binary), str(project), "--contract", "Factory", "--disable-slither",
                       "--config", str(config), "--workers", "1", "--seq-len", "1",
                       "--test-limit", str(limit), "--seed", "12345", "--format", "text",
                       "+RTS", "-N1", "-A4m", "-s"]
            run = subprocess.run(command, cwd=directory, env=env, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
            label = f"{variant}-{limit}"
            (output / (label + ".log")).write_text(run.stdout)
            result = {"case": label, "exit": run.returncode}
            for key, pattern in [
                ("owners", r"Unique codehashes: (\d+)"),
                ("instructions", r"Unique instructions: (\d+)"),
                ("corpus", r"Corpus size: (\d+)"),
                ("maximum_live_heap_bytes", r"([\d,]+) bytes maximum residency"),
            ]:
                match = re.search(pattern, run.stdout)
                result[key] = int(match[1].replace(",", "")) if match else None
            results.append(result)
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            assert run.returncode == 0, run.stdout[-4000:]
            assert "echidna_ok: passing" in run.stdout, "property did not pass"
            assert result["owners"] == 2, "deployment variants duplicated contract coverage"
            assert result["instructions"] > 0, "coverage must remain enabled"
            assert result["corpus"] <= 10, "deployment variants inflated the corpus"
            assert result["maximum_live_heap_bytes"] < 32 * 1024 * 1024, "unbounded retained heap"
    print("All memory regressions passed with coverage enabled.")


if __name__ == "__main__":
    main()
