"""Write chunk outputs into a Jupyter notebook, for lua/config/kernel/ipynb.lua.

    python -I ipynb.py NOTEBOOK.ipynb < outputs.json

outputs.json maps a code cell's index (among code cells, from 0) to
{"execution_count": n or null, "outputs": [nbformat outputs]}. An output may
carry "png_path" instead of the image data; the file is embedded as base64.
Cells not listed keep their outputs. Written the way Jupyter writes notebooks
(indent 1, UTF-8, trailing newline).
"""

import base64
import json
import sys


def main():
    path = sys.argv[1]
    new = json.load(sys.stdin)
    with open(path, encoding="utf-8") as f:
        nb = json.load(f)
    code = [c for c in nb.get("cells", []) if c.get("cell_type") == "code"]
    for key, cell_out in new.items():
        i = int(key)
        if i >= len(code):
            continue
        outputs = []
        for o in cell_out["outputs"]:
            png = o.pop("png_path", None)
            if png:
                with open(png, "rb") as f:
                    o.setdefault("data", {})["image/png"] = base64.b64encode(
                        f.read()
                    ).decode()
            outputs.append(o)
        code[i]["outputs"] = outputs
        code[i]["execution_count"] = cell_out.get("execution_count")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(nb, f, indent=1, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
