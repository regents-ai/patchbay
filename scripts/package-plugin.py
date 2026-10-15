# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema==4.25.1"]
# ///
"""Validate and package the free Patchbay plugin without publishing it."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import zipfile

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "plugins" / "patchbay"
FILES = ("README.md", "assets/icon.svg", "mcp.json", "plugin.json",
         "skills/patchbay-post/SKILL.md", "skills/patchbay-reply/SKILL.md",
         "skills/patchbay-check-updates/SKILL.md")


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def package(output: Path) -> str:
    contents = {}
    for name in FILES:
        path = PACKAGE / name
        check(not path.is_symlink() and path.is_file()
              and path.resolve().is_relative_to(PACKAGE.resolve()),
              f"Missing or unsafe package file: {name}")
        contents[name] = path.read_bytes()

    plugin = json.loads(contents["plugin.json"])
    mcp = json.loads(contents["mcp.json"])
    expected_server = {
        "type": "streamable-http", "url": "https://patchbay.help/chatgpt/mcp",
        "extensions": {"com.openai": {"auth": {
            "type": "mixed", "client": {"mode": "dcr"},
            "resource": "https://patchbay.help/chatgpt/mcp",
            "baseScopes": ["patchbay.events.read"]
        }}}
    }
    check(mcp["mcpServers"] == {"patchbay": expected_server},
          "Use the exact public endpoint and documented OAuth settings without credentials.")
    # The portable 1.0 schema currently excludes OpenAI's documented server
    # extensions. Validate that extension exactly above, then the portable shape.
    portable_mcp = copy.deepcopy(mcp)
    del portable_mcp["mcpServers"]["patchbay"]["extensions"]
    for name, document in (("plugin", plugin), ("mcp", portable_mcp)):
        schema = json.loads((ROOT / "scripts" / "plugin-schemas" / f"{name}.schema.json").read_text())
        Draft202012Validator(schema).validate(document)

    settings = plugin["extensions"]["com.openai"]
    check(settings["interface"]["capabilities"] == ["Read", "Write"], "Only free reading and authorized participation are supported.")
    check(settings["review"]["commerce"] is False, "Commerce must stay off.")
    cases = settings["review"]["test_cases"]
    check(len(cases["positive"]) == 5 and len(cases["negative"]) == 3,
          "Review requires five positive and three negative cases.")


    manifest = json.loads((ROOT / "platform" / "priv" / "tool_manifest.json").read_text())
    reads = {tool["name"] for tool in manifest["tools"]
             if tool["requires"] == "none" and not tool["state_changing"]
             and tool["payment"] == "none" and tool["annotations"].get("readOnlyHint")
             and tool["doors"].get("hosted")
             and tool["name"] not in {"get_agent_profile", "list_offer_slots"}}
    check(len(reads) == 7, "Expected exactly seven public read tools.")
    available = reads | {"register_identity", "get_identity", "pair_identity", "ask_question", "post_reply"}
    for case in cases["positive"]:
        names = {name.strip() for name in case["tools_triggered"].split(",")}
        check(names and names <= available, "A positive case names an unavailable public tool.")
    for key in ("composerIcon", "logo"):
        check(settings["interface"][key].removeprefix("./") in contents,
              f"The {key} asset is not in the package.")

    output = output.resolve()
    check(not output.is_relative_to(PACKAGE), "Write the ZIP outside its source directory.")
    check(not output.exists(), "Refusing to replace an existing artifact; choose a new output path.")
    check(not output.with_suffix(output.suffix + ".sha256").exists(),
          "Refusing to replace an existing artifact hash.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(contents.items()):
            item = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = 0o100644 << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data, compresslevel=9)
    with zipfile.ZipFile(output) as archive:
        check(archive.testzip() is None and archive.namelist() == sorted(FILES),
              "The completed ZIP failed its contents check.")
        check(all(archive.read(name) == contents[name] for name in FILES),
              "The ZIP differs from its source.")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n")
    return digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        digest = package(args.output)
    except (ValueError, KeyError) as error:
        parser.exit(1, f"Package refused: {error}\n")
    print(f"Validated {args.output.name}; SHA-256 {digest}")
