#!/usr/bin/env python3
"""Check indexed project switching and isolated chat, memory, and skill state."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from smoke import clean_environment, run_repl


def run():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="pmai-projects-") as directory:
        root = Path(directory).resolve()
        one, two, new = [root / name for name in ["one", "two", "new project"]]
        for path in [one, two, new]:
            path.mkdir()
        home = root / "home"
        config = root / "settings.json"
        config.write_text(json.dumps({"defaultAgent": "main", "providers": [{"id": "hello", "kind": "hello"}],
            "agents": [{"id": "main", "provider": "hello", "model": "hello"}], "use": {"plan": False}}))
        command = [binary, "--home", str(home), "--config", str(config), "--no-markdown"]
        for path, prompt in [(one, "first project chat"), (two, "second project chat")]:
            result = subprocess.run(command + [prompt], cwd=path, env=clean_environment(),
                                    capture_output=True, text=True, timeout=25)
            assert result.returncode == 0, result.stderr
        for path, marker, skill in [(one, "FIRST_PROJECT_MEMORY", "first-project-skill"),
                                    (two, "SECOND_PROJECT_MEMORY", "second-project-skill")]:
            run_repl(command, ["/memory add " + marker], cwd=path, env=clean_environment())
            skill_dir = path / ".pmai/skills" / skill
            skill_dir.mkdir(parents=True)
            (skill_dir / "SKILL.md").write_text(f"---\nname: {skill}\ndescription: Test project skill\n---\nTest instructions.\n")
        files_one = set((one / ".pmai/chats").glob("*.json"))
        files_two = set((two / ".pmai/chats").glob("*.json"))
        if os.name != "nt":
            # Catch inflated totals from sparse files, hard links, or following
            # symlinks outside storage, and omitted nested/hidden storage files.
            nested = two / ".pmai/.cache/nested"
            nested.mkdir(parents=True)
            payload = nested / "payload"
            payload.write_bytes(b"x" * 32768)
            os.link(payload, nested / "hardlink")
            with (nested / "sparse").open("wb") as stream:
                stream.truncate(64 * 1024 * 1024)
            outside = root / "outside"
            outside.mkdir()
            (outside / "payload").write_bytes(b"x" * 524288)
            (nested / "external").symlink_to(outside, target_is_directory=True)
            (nested / "loop").symlink_to(two / ".pmai", target_is_directory=True)
        output = run_repl(command, ["/projects", "/projects open two", "/project", "/chat list", "/memory", "/skills list",
            "/projects rename one First", "/projects tint First mint", "/projects open First",
            "/project", "/chat list", "/memory", "/skills list", f'/projects open "{new}"', "/chat rename newly opened",
            "/projects open two", f'/projects del "{new}"'], cwd=one, env=clean_environment())
        assert "Opened project 'two'" in output, output
        assert "second project chat" in output, output
        assert "Opened project 'First'" in output, output
        assert "first project chat" in output, output
        assert "Tint:      mint" in output, output
        assert "Forgot 'new project'" in output, output
        assert "FIRST_PROJECT_MEMORY" in output and "SECOND_PROJECT_MEMORY" in output, output
        assert "first-project-skill" in output and "second-project-skill" in output, output
        assert "Disk" in output, output
        assert set((one / ".pmai/chats").glob("*.json")) == files_one
        assert set((two / ".pmai/chats").glob("*.json")) == files_two
        assert any(json.loads(p.read_text())["title"] == "newly opened" for p in (new / ".pmai/chats").glob("*.json"))
        index = json.loads((home / "projects.json").read_text())
        assert {p["name"] or Path(p["workingDirectory"]).name for p in index["projects"]} == {"First", "two"}
        if os.name != "nt":
            def check_usage(listing, name, storage):
                row = re.search(r"^\s*\*?\s+\d+\s+" + name + r"\s+(\S+)", listing, re.MULTILINE)
                assert row, listing
                size = re.fullmatch(r"([\d.]+)([BKMGTPE])", row[1])
                assert size, row[0]
                scale = 1024 ** "BKMGTPE".index(size[2])
                actual = float(size[1]) * scale
                usage = subprocess.run(["du", "-sk", str(storage)], check=True,
                                       capture_output=True, text=True, timeout=25)
                expected = int(usage.stdout.split()[0]) * 1024
                assert abs(actual - expected) <= max(1024, scale * .051), (row[0], usage.stdout)

            check_usage(output, "two", two / ".pmai")
            fallback = dict(index["projects"][0], id=str(uuid.uuid4()).upper(), name="fallback",
                            workingDirectory=str(root / "gone"))
            missing = dict(fallback, id=str(uuid.uuid4()).upper(), name="missing",
                           workingDirectory=str(root / "missing"))
            storage = home / "projects" / fallback["id"]
            storage.mkdir(parents=True)
            (storage / "payload").write_bytes(b"x" * 16384)
            index["projects"].extend([fallback, missing])
            (home / "projects.json").write_text(json.dumps(index))
            listing = subprocess.run(command + ["--projects"], cwd=one, env=clean_environment(),
                                     check=True, capture_output=True, text=True, timeout=25).stdout
            check_usage(listing, "First", one / ".pmai")
            check_usage(listing, "two", two / ".pmai")
            check_usage(listing, "fallback", storage)
            assert re.search(r"^\s*\d+\s+missing\s+-\s", listing, re.MULTILINE), listing
            print("Project disk usage matches du, includes fallback storage, and handles missing storage: passed")
        print("/projects lists, switches chats and cwd, renames, colors, opens new directories, and forgets without deleting data: passed")


if __name__ == "__main__":
    run()
