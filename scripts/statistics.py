import urllib.request
import subprocess
import sys


def collect(d):
    try:
        n_admitted = len(subprocess.check_output(
            ["grep", "-r", "-E", "Admitted", d]).splitlines())
    except: n_admitted = 0

    try: n_theorems = len(subprocess.check_output(
            ["grep", "-r", "-E", "Theorem|Lemma|Remark", d]).splitlines())
    except: n_theorems = 0

    try: n_qed = len(subprocess.check_output(
            ["grep", "-r", "-E", "Qed|Defined", d]).splitlines())
    except: n_qed = 0

    return (n_admitted, n_theorems, n_qed)


def pick_colour(n, m):
    if n > 0.2 * m: return "red"
    elif n > 0.1 * m: return "orange"
    elif n == 0: return "brightgreen"
    else: return "yellow"


def main(d):
    n_admitted, n_theorems, _ = collect(d)
    colour = pick_colour(n_admitted, n_theorems)

    url = "https://img.shields.io/badge/admitted%20proofs-{}-{}?style=flat".format(
        str(n_admitted), colour)

    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with open("admitted.svg", "wb") as f:
        with urllib.request.urlopen(req) as r:
            f.write(r.read())


if __name__ == "__main__":
    main(sys.argv[1])
