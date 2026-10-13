#!/usr/bin/env python3
"""Check indexed project switching and isolated chat, memory, and skill state."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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
        output = run_repl(command, ["/projects", "/projects open two", "/project", "/chat list", "/memory", "/skills list",
            "/projects rename one First", "/projects tint First mint", "/projects switch First",
            "/project", "/chat list", "/memory", "/skills list", f'/projects open "{new}"', "/chat rename newly opened",
            "/projects open two", f'/projects forget "{new}"'], cwd=one, env=clean_environment())
        assert "Opened project 'two'" in output, output
        assert "second project chat" in output, output
        assert "Opened project 'First'" in output, output
        assert "first project chat" in output, output
        assert "Tint:      mint" in output, output
        assert "Forgot 'new project'" in output, output
        assert "FIRST_PROJECT_MEMORY" in output and "SECOND_PROJECT_MEMORY" in output, output
        assert "first-project-skill" in output and "second-project-skill" in output, output
        assert set((one / ".pmai/chats").glob("*.json")) == files_one
        assert set((two / ".pmai/chats").glob("*.json")) == files_two
        assert any(json.loads(p.read_text())["title"] == "newly opened" for p in (new / ".pmai/chats").glob("*.json"))
        index = json.loads((home / "projects.json").read_text())
        assert {p["name"] or Path(p["workingDirectory"]).name for p in index["projects"]} == {"First", "two"}
        print("/projects lists, switches chats and cwd, renames, colors, opens new directories, and forgets without deleting data: passed")


if __name__ == "__main__":
    run()
