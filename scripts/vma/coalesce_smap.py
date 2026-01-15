import csv
import os
import sys


def parse_int(value: str) -> int:
	return int(str(value), 16)


def load_rows(path: str):
	with open(path, newline="") as f:
		reader = csv.DictReader(f)
		rows = []
		for row in reader:
			row["start"] = parse_int(row["start"])
			row["end"] = parse_int(row["end"])
			row["rss_kb"] = int(row["rss_kb"])
			rows.append(row)
	return rows


def deduplicate(rows):
	# Keep highest rss_kb per start
	rows = sorted(rows, key=lambda r: (r["start"], r["end"], -r["rss_kb"]))
	start_map = {}
	for r in rows:
		if r["start"] not in start_map:
			start_map[r["start"]] = r

	# Keep highest rss_kb per end
	end_map = {}
	for r in sorted(start_map.values(), key=lambda r: (r["end"], -r["rss_kb"])):
		end_map.setdefault(r["end"], r)

	return sorted(end_map.values(), key=lambda r: (r["start"], r["end"]))


def write_rows(path: str, rows):
	out_path = os.path.splitext(path)[0] + "_smap_deduplicated.csv"
	if not rows:
		open(out_path, "w").write("")
		return out_path

	fieldnames = list(rows[0].keys())
	with open(out_path, "w", newline="") as f:
		writer = csv.DictWriter(f, fieldnames=fieldnames)
		writer.writeheader()
		for r in rows:
			r = r.copy()
			r["start"] = hex(r["start"])
			r["end"] = hex(r["end"])
			writer.writerow(r)
	return out_path


def main():
	if len(sys.argv) < 2:
		raise SystemExit("usage: coalesce_smap.py <memory_regions.csv>")

	src = sys.argv[1]
	rows = load_rows(src)
	deduped = deduplicate(rows)
	out = write_rows(src, deduped)
	print(f"wrote {out}")


if __name__ == "__main__":
	main()

