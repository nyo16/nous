"""Golden values for Nous.Eval.Stats (test/nous/eval/stats*).

Run once from the repository root and commit the JSON it writes:

    uv run --with scipy --with statsmodels --with numpy --with scikit-learn \
        --with mpmath python test/fixtures/stats/generate.py

Every JSON file records the library versions in "meta" and, per family, which
reference produced the expected values:

* SciPy / statsmodels / scikit-learn where they implement the quantity.
* exact rational arithmetic (fractions + math.comb) for pass@k and pass^k.
* mpmath at 50 digits for what none of them ship (Tango's paired score test
  and interval, Connor's McNemar power, the Nam/Tango non-inferiority power).
  The Tango reference does NOT reuse the closed-form restricted MLE that the
  Elixir code uses: it maximises the constrained multinomial likelihood
  numerically, so it checks that closed form independently.
"""

import json
import math
import platform
from fractions import Fraction
from pathlib import Path

import mpmath
import numpy as np
import scipy
import sklearn
import statsmodels
import statsmodels.api as sm
from scipy import special, stats
from sklearn import metrics as skm
from statsmodels.stats.contingency_tables import mcnemar as sm_mcnemar
from statsmodels.stats.multitest import multipletests
from statsmodels.stats.power import NormalIndPower
from statsmodels.stats.proportion import proportion_confint, proportion_effectsize

mpmath.mp.dps = 50

OUT = Path(__file__).parent
META = {
    "generator": "test/fixtures/stats/generate.py",
    "python": platform.python_version(),
    "numpy": np.__version__,
    "scipy": scipy.__version__,
    "statsmodels": statsmodels.__version__,
    "scikit-learn": sklearn.__version__,
    "mpmath": mpmath.__version__,
}


def write(name, sources, data):
    payload = {"meta": {**META, "sources": sources}, **data}
    text = json.dumps(payload, indent=2, allow_nan=False)
    (OUT / f"{name}.json").write_text(text + "\n")


def fl(x):
    return float(x)


def mp_t_ppf(p, df):
    """Student t quantile at 50 digits. scipy.stats.t.ppf (stdtrit) is off by
    up to ~2e-9 relative (df=4, p=0.95: 2.13184678134 vs 2.13184678633), far
    more than our tolerance."""
    p, df = mpmath.mpf(p), mpmath.mpf(df)

    def cdf(t):
        tail = mpmath.betainc(df / 2, mpmath.mpf(1) / 2, 0, df / (df + t * t), regularized=True) / 2
        return 1 - tail if t >= 0 else tail

    return mpmath.findroot(lambda t: cdf(t) - p, mpmath.mpf(stats.t.ppf(float(p), float(df))))


# ── special functions ─────────────────────────────────────────────────────


def special_fixture():
    lgamma = [1e-8, 0.001, 0.1, 0.3, 0.5, 1.0, 1.5, 2.0, 2.5, 3.7, 10.0, 33.3, 100.5, 1e4, 1e6]
    betainc = [
        (0.5, 0.5, 0.3),
        (1.0, 1.0, 0.42),
        (2.0, 3.0, 0.4),
        (10.0, 20.0, 0.3),
        (100.0, 200.0, 0.33),
        (1000.0, 5000.0, 0.17),
        (0.1, 10.0, 0.01),
        (50.5, 0.5, 0.99),
        (3.0, 1e4, 0.0002),
        (5.0, 5.0, 0.999),
        (0.5, 30.0, 0.9),
        (2500.0, 2500.0, 0.51),
    ]
    beta_quantile = [
        (0.025, 1.0, 100.0),
        (0.975, 5.0, 3.0),
        (1e-6, 2.0, 2.0),
        (0.5, 0.5, 0.5),
        (0.05, 0.5, 300.5),
        (0.995, 40.5, 1.5),
        (0.3, 700.0, 300.0),
        (0.9, 1.0, 1.0),
    ]
    norm_cdf = [-37.0, -10.0, -5.0, -1.959963984540054, -1.0, -0.1, 0.0, 0.5, 1.0, 3.0, 8.0]
    norm_quantile = [
        1e-300, 1e-100, 1e-12, 1e-6, 0.001, 0.02, 0.02425, 0.025, 0.1, 0.3, 0.5,
        0.6, 0.8, 0.95, 0.975, 0.999, 0.999999, 1 - 1e-12,
    ]
    t_cdf = [(-3.0, 2.0), (-1.0, 5.0), (0.3, 1.0), (2.0, 10.0), (2.228, 10.0), (1.5, 2.5), (-0.5, 200.0)]
    t_quantile = [(0.975, 1.0), (0.975, 2.0), (0.975, 10.0), (0.95, 30.0), (0.005, 4.0), (0.6, 7.0), (0.999, 3.5)]
    quantile_values = [3.2, -1.0, 7.5, 0.0, 2.2, 2.2, 9.9, 4.1, 5.0, -3.3, 1.0]
    probs = [0.0, 0.025, 0.1, 0.25, 0.5, 0.75, 0.9, 0.975, 1.0]

    write(
        "special",
        {
            "lgamma": "scipy.special.gammaln",
            "betainc": "scipy.special.betainc",
            "beta_quantile": "scipy.special.betaincinv",
            "norm_cdf": "scipy.special.ndtr",
            "norm_quantile": "scipy.special.ndtri",
            "t_cdf": "scipy.stats.t.cdf",
            "t_quantile": "mpmath root of the regularized-incomplete-beta t CDF (scipy.stats.t.ppf is only ~1e-9 accurate)",
            "quantile": "numpy.quantile(method='linear') (Hyndman-Fan type 7)",
        },
        {
            "lgamma": [{"x": x, "expected": fl(special.gammaln(x))} for x in lgamma],
            "betainc": [
                {"a": a, "b": b, "x": x, "expected": fl(special.betainc(a, b, x))} for a, b, x in betainc
            ],
            "beta_quantile": [
                {"p": p, "a": a, "b": b, "expected": fl(special.betaincinv(a, b, p))}
                for p, a, b in beta_quantile
            ],
            "norm_cdf": [{"x": x, "expected": fl(special.ndtr(x))} for x in norm_cdf],
            "norm_quantile": [{"p": p, "expected": fl(special.ndtri(p))} for p in norm_quantile],
            "t_cdf": [{"t": t, "df": df, "expected": fl(stats.t.cdf(t, df))} for t, df in t_cdf],
            "t_quantile": [{"p": p, "df": df, "expected": fl(mp_t_ppf(p, df))} for p, df in t_quantile],
            "quantile": {
                "values": quantile_values,
                "probs": probs,
                "expected": [fl(q) for q in np.quantile(quantile_values, probs, method="linear")],
            },
        },
    )


# ── descriptives ──────────────────────────────────────────────────────────


def descriptives_fixture():
    rng = np.random.default_rng(20261101)
    samples = [
        [round(float(v), 6) for v in rng.normal(0.6, 0.2, 37)],
        [0.0, 1.0, 1.0, 0.0, 1.0],
        [1e9 + 4, 1e9 + 7, 1e9 + 13, 1e9 + 16],  # Welford stability
        [0.25, 0.25, 0.25],
    ]

    describe = []
    mean_ci = []
    for values in samples:
        arr = np.array(values)
        describe.append(
            {"values": values, "mean": fl(arr.mean()), "variance": fl(arr.var(ddof=1))}
        )
        sem = stats.sem(arr)
        for conf in (0.95, 0.9):
            t = mp_t_ppf(1 - (1 - conf) / 2, len(arr) - 1)
            lo, hi = fl(arr.mean() - t * sem), fl(arr.mean() + t * sem)
            if sem > 0:
                ref = stats.t.interval(conf, len(arr) - 1, loc=arr.mean(), scale=sem)
                # scipy's t.ppf is off by up to ~2e-9 relative (df=4, p=0.95).
                half = fl(t * sem)
                assert abs(ref[0] - lo) <= 1e-8 * half and abs(ref[1] - hi) <= 1e-8 * half
            mean_ci.append({"values": values, "confidence": conf, "lower": lo, "upper": hi})

    clusters = [
        [[1.0, 1.0, 0.0], [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]],
        [[1.0, 0.0], [0.5], [0.2, 0.4, 0.9, 1.0], [0.0, 0.0, 1.0], [0.7, 0.8]],
        [[0.3], [0.9], [0.1], [0.6], [0.8]],
        [[round(float(v), 4) for v in rng.uniform(0, 1, size)] for size in rng.integers(1, 6, 12)],
    ]
    clustered = []
    for groups in clusters:
        y = np.concatenate([np.array(g, dtype=float) for g in groups])
        ids = np.concatenate([np.full(len(g), i) for i, g in enumerate(groups)])
        res = sm.OLS(y, np.ones(len(y))).fit(cov_type="cluster", cov_kwds={"groups": ids})
        clustered.append({"clusters": groups, "mean": fl(res.params[0]), "se": fl(res.bse[0])})

    # Singleton clusters reduce to the ordinary standard error.
    assert abs(clustered[2]["se"] - stats.sem([0.3, 0.9, 0.1, 0.6, 0.8])) < 1e-12
    # Equal-size clusters reduce to the standard error of cluster means.
    assert abs(clustered[0]["se"] - stats.sem([2 / 3, 0.0, 1.0])) < 1e-12

    pairs = [
        ([0.9, 0.8, 0.7, 1.0], [0.8, 0.8, 0.5, 0.9]),
        (
            [round(float(v), 4) for v in rng.uniform(0, 1, 25)],
            [round(float(v), 4) for v in rng.uniform(0, 1, 25)],
        ),
    ]
    paired = []
    for cand, base in pairs:
        d = np.array(cand) - np.array(base)
        paired.append(
            {
                "candidate": cand,
                "baseline": base,
                "mean_difference": fl(d.mean()),
                "se": fl(stats.sem(d)),
                "correlation": fl(np.corrcoef(cand, base)[0, 1]),
            }
        )

    write(
        "descriptives",
        {
            "describe": "numpy mean / var(ddof=1)",
            "mean_ci": "mean -/+ t * scipy.stats.sem, t from mpmath (cross-checked against scipy.stats.t.interval to 1e-8 of the half-width)",
            "clustered_se": "statsmodels OLS(y, 1).fit(cov_type='cluster') bse (CR1)",
            "paired_se": "scipy.stats.sem of differences; numpy.corrcoef",
        },
        {"describe": describe, "mean_ci": mean_ci, "clustered_se": clustered, "paired_se": paired},
    )


# ── proportions ───────────────────────────────────────────────────────────


def proportions_fixture():
    cases = [(0, 10), (1, 10), (5, 10), (10, 10), (33, 41), (0, 300), (61, 140), (1, 1), (999, 1000), (17, 18), (3, 2000)]
    rows = []
    for x, n in cases:
        for conf in (0.95, 0.9, 0.99):
            alpha = 1 - conf
            row = {"successes": x, "n": n, "confidence": conf}
            for name, method in (("wilson", "wilson"), ("clopper_pearson", "beta"), ("jeffreys", "jeffreys")):
                lo, hi = proportion_confint(x, n, alpha=alpha, method=method)
                row[name] = [fl(lo), fl(hi)]
            rows.append(row)

    posterior = []
    for x, n, prior in [(8, 10, (1, 1)), (0, 0, (1, 1)), (0, 25, (1, 1)), (41, 41, (0.5, 0.5)), (12, 30, (2, 5))]:
        a, b = prior[0] + x, prior[1] + n - x
        dist = stats.beta(a, b)
        posterior.append(
            {
                "successes": x,
                "n": n,
                "prior": list(prior),
                "mean": fl(dist.mean()),
                "lower": fl(dist.ppf(0.025)),
                "upper": fl(dist.ppf(0.975)),
            }
        )

    write(
        "proportions",
        {
            "wilson": "statsmodels proportion_confint(method='wilson')",
            "clopper_pearson": "statsmodels proportion_confint(method='beta')",
            "jeffreys": "statsmodels proportion_confint(method='jeffreys')",
            "beta_posterior": "scipy.stats.beta mean/ppf (equal-tailed 95%)",
        },
        {"intervals": rows, "beta_posterior": posterior},
    )


# ── pass@k / pass^k ───────────────────────────────────────────────────────


def pass_k_fixture():
    cases = [
        (1, 0, 1), (1, 1, 1), (3, 1, 1), (3, 1, 2), (3, 2, 3), (5, 3, 3), (10, 3, 1), (10, 3, 5),
        (10, 10, 10), (10, 0, 4), (20, 7, 8), (200, 37, 50), (1000, 3, 100), (1000, 997, 100),
    ]
    rows = []
    for n, c, k in cases:
        at = 1 - Fraction(math.comb(n - c, k), math.comb(n, k))
        hat = Fraction(math.comb(c, k), math.comb(n, k))
        rows.append({"n": n, "c": c, "k": k, "pass_at_k": fl(at), "pass_hat_k": fl(hat)})

    write(
        "pass_k",
        {
            "pass_at_k": "exact 1 - C(n-c,k)/C(n,k) with fractions.Fraction (Chen et al. 2021, eq. 1)",
            "pass_hat_k": "exact C(c,k)/C(n,k) with fractions.Fraction (Yao et al. 2024, tau-bench, sec. 3)",
        },
        {"cases": rows},
    )


# ── hypothesis tests ──────────────────────────────────────────────────────


def tango_restricted_q(b, c, n, delta):
    """c-cell probability maximising the multinomial likelihood under
    p_b - p_c = delta, found by bisection on the score equation."""
    b, c, n, delta = (mpmath.mpf(v) for v in (b, c, n, delta))
    m = n - b - c
    lo = max(mpmath.mpf(0), -delta)
    hi = (1 - delta) / 2

    def score(q):
        s = mpmath.mpf(0)
        if b > 0:
            s += b / (q + delta)
        if c > 0:
            s += c / q
        if m > 0:
            s -= 2 * m / (1 - 2 * q - delta)
        return s

    eps = mpmath.mpf(10) ** -40
    if hi - lo <= eps:
        return lo
    if score(lo + eps) <= 0:
        return lo
    if score(hi - eps) >= 0:
        return hi
    a, z = lo + eps, hi - eps
    for _ in range(400):
        mid = (a + z) / 2
        if score(mid) > 0:
            a = mid
        else:
            z = mid
    return (a + z) / 2


def tango_numerator_and_var(b, c, n, delta):
    delta = mpmath.mpf(delta)
    q = tango_restricted_q(b, c, n, delta)
    var = 2 * q + delta - delta**2
    return mpmath.mpf(b - c) - n * delta, n * max(var, mpmath.mpf(0))


def tango_z(b, c, n, delta):
    num, var = tango_numerator_and_var(b, c, n, delta)
    if var == 0:
        return mpmath.mpf(0)
    return num / mpmath.sqrt(var)


def tango_ci(b, c, n, conf):
    # Two-sided critical value: Phi^-1(1 - alpha/2) = sqrt(2) * erfinv(conf).
    z = mpmath.sqrt(2) * mpmath.erfinv(mpmath.mpf(conf))
    est = mpmath.mpf(b - c) / n

    def side(d, sign):
        num, var = tango_numerator_and_var(b, c, n, d)
        return num + sign * z * mpmath.sqrt(var)

    def root(sign, lo, hi):
        for _ in range(300):
            mid = (lo + hi) / 2
            if side(mid, sign) > 0:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2

    lower = mpmath.mpf(-1) if side(mpmath.mpf(-1), -1) <= 0 else root(-1, mpmath.mpf(-1), est)
    upper = mpmath.mpf(1) if side(mpmath.mpf(1), 1) >= 0 else root(1, est, mpmath.mpf(1))
    return lower, upper


def hypothesis_fixture():
    mcnemar_rows = []
    for b, c in [(0, 0), (1, 0), (0, 5), (5, 0), (3, 3), (2, 9), (12, 25), (40, 60), (150, 180), (1000, 1100), (0, 30)]:
        n = b + c
        k = min(b, c)
        exact = sm_mcnemar([[0, b], [c, 0]], exact=True).pvalue
        mid = 1.0 if n == 0 else min(1.0, 2 * (stats.binom.cdf(k, n, 0.5) - 0.5 * stats.binom.pmf(k, n, 0.5)))
        mcnemar_rows.append({"b": b, "c": c, "p_value": fl(exact), "mid_p_value": fl(mid)})

    fisher_rows = []
    for table in [
        [[3, 1], [1, 3]], [[1, 9], [11, 3]], [[8, 2], [1, 5]], [[0, 5], [5, 0]], [[5, 5], [5, 5]],
        [[12, 5], [3, 20]], [[100, 90], [80, 110]], [[2, 7], [8, 2]], [[3, 0], [0, 3]],
        [[0, 0], [3, 4]], [[0, 0], [0, 0]], [[7, 0], [2, 0]], [[1, 2], [0, 3]],
    ]:
        res = stats.fisher_exact(table, alternative="two-sided")
        odds = fl(res.statistic)
        odds_out = "infinity" if math.isinf(odds) else ("undefined" if math.isnan(odds) else odds)
        p = 1.0 if math.isnan(res.pvalue) else fl(res.pvalue)
        fisher_rows.append({"table": table, "p_value": p, "odds_ratio": odds_out})

    tango_cases = [
        (1, 0, 61), (0, 0, 61), (0, 0, 52), (5, 2, 100), (2, 5, 100), (10, 3, 41), (0, 7, 20),
        (7, 0, 20), (20, 0, 20), (0, 20, 20), (3, 3, 50), (15, 40, 300), (9, 4, 50), (1, 1, 2),
    ]
    tango_tests = []
    for b, c, n in tango_cases:
        for delta0 in (0.0, 0.05, -0.1, 0.02):
            z = tango_z(b, c, n, delta0)
            row = {"b": b, "c": c, "n": n, "delta0": delta0, "z": fl(z)}
            if delta0 == 0.0 and b + c > 0:
                # At delta0 = 0 Tango's Z^2 is McNemar's uncorrected chi-square.
                row["mcnemar_chi2"] = fl(sm_mcnemar([[0, b], [c, 0]], exact=False, correction=False).statistic)
                assert abs(row["mcnemar_chi2"] - fl(z) ** 2) < 1e-9
            tango_tests.append(row)
    tango_cis = []
    for b, c, n in tango_cases:
        for conf in (0.95, 0.9):
            lo, hi = tango_ci(b, c, n, conf)
            tango_cis.append({"b": b, "c": c, "n": n, "confidence": conf, "lower": fl(lo), "upper": fl(hi)})

    p_sets = [
        [0.01, 0.04, 0.03],
        [0.001, 0.008, 0.039, 0.041, 0.042, 0.06, 0.074, 0.205, 0.212, 0.216],
        [0.5, 0.5, 0.01, 0.01, 0.2],
        [0.9],
        [0.0, 1.0, 0.049, 0.051],
        [0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1, 0.11, 0.12, 0.8],
    ]
    adjust = []
    for ps in p_sets:
        holm = multipletests(ps, alpha=0.05, method="holm")
        bh = multipletests(ps, alpha=0.05, method="fdr_bh")
        adjust.append(
            {
                "p_values": ps,
                "holm": [fl(v) for v in holm[1]],
                "holm_rejected": [bool(v) for v in holm[0]],
                "bh": [fl(v) for v in bh[1]],
                "bh_rejected": [bool(v) for v in bh[0]],
            }
        )

    write(
        "hypothesis",
        {
            "mcnemar.p_value": "statsmodels contingency_tables.mcnemar(exact=True)",
            "mcnemar.mid_p_value": "2*(binom.cdf(k) - binom.pmf(k)/2) with scipy.stats.binom (Fagerland et al. 2013)",
            "fisher_exact": "scipy.stats.fisher_exact(alternative='two-sided'); NaN odds ratio -> 'undefined', all-zero table p -> 1.0",
            "tango": (
                "mpmath (50 digits) independent reference: restricted MLE by bisection on the constrained "
                "multinomial score equation, Z = (b-c-n*d)/sqrt(n*(2q+d-d^2)) (Tango 1998); CI by bisection "
                "on |Z| = z. Cross-checked at d=0 against statsmodels mcnemar(exact=False, correction=False)."
            ),
            "holm, bh": "statsmodels multipletests(method='holm' / 'fdr_bh', alpha=0.05)",
        },
        {
            "mcnemar": mcnemar_rows,
            "fisher_exact": fisher_rows,
            "tango_test": tango_tests,
            "tango_ci": tango_cis,
            "adjust": adjust,
        },
    )


# ── power ─────────────────────────────────────────────────────────────────


def mp_z(p):
    return mpmath.sqrt(2) * mpmath.erfinv(2 * mpmath.mpf(p) - 1)


def mp_phi(x):
    return mpmath.ncdf(x)


def ni_spreads(pb, pc, margin):
    pb, pc, m = (mpmath.mpf(v) for v in (pb, pc, margin))
    a = mpmath.mpf(2)
    b = -(pb + pc) + (2 - pb + pc) * m
    c = -pc * m * (1 - m)
    q = (mpmath.sqrt(b * b - 4 * a * c) - b) / (2 * a)
    delta = pb - pc
    return mpmath.sqrt(2 * q + m * (1 - m)), mpmath.sqrt(pb + pc - delta**2)


def power_fixture():
    two_prop = []
    for p1, p2, n, alpha in [(0.6, 0.7, 356, 0.05), (0.5, 0.6, 100, 0.05), (0.2, 0.1, 50, 0.01), (0.9, 0.95, 400, 0.1)]:
        h = proportion_effectsize(p1, p2)
        power = NormalIndPower().power(effect_size=h, nobs1=n, alpha=alpha, ratio=1.0, alternative="two-sided")
        two_prop.append({"p1": p1, "p2": p2, "n": n, "alpha": alpha, "power": fl(power)})
    two_prop_n = []
    for p1, p2, alpha, power in [(0.6, 0.7, 0.05, 0.8), (0.5, 0.6, 0.05, 0.9), (0.2, 0.1, 0.01, 0.8), (0.8, 0.85, 0.05, 0.8)]:
        h = proportion_effectsize(p1, p2)
        n = NormalIndPower().solve_power(effect_size=h, nobs1=None, alpha=alpha, power=power, ratio=1.0, alternative="two-sided")
        two_prop_n.append({"p1": p1, "p2": p2, "alpha": alpha, "power": power, "n": math.ceil(n)})

    mcn = []
    for pb, pc, n, alpha in [(0.15, 0.05, 150, 0.05), (0.1, 0.2, 80, 0.05), (0.3, 0.25, 500, 0.01), (0.02, 0.0, 300, 0.05)]:
        psi, d = mpmath.mpf(pb) + pc, abs(mpmath.mpf(pb) - pc)
        za = mp_z(1 - mpmath.mpf(alpha) / 2)
        power = mp_phi((d * mpmath.sqrt(n) - za * mpmath.sqrt(psi)) / mpmath.sqrt(psi - d * d))
        mcn.append({"p_b": pb, "p_c": pc, "n": n, "alpha": alpha, "power": fl(power)})
    mcn_n = []
    for pb, pc, alpha, power in [(0.15, 0.05, 0.05, 0.8), (0.1, 0.2, 0.05, 0.9), (0.3, 0.25, 0.01, 0.8)]:
        psi, d = mpmath.mpf(pb) + pc, mpmath.mpf(pb) - pc
        za, zb = mp_z(1 - mpmath.mpf(alpha) / 2), mp_z(power)
        n = (za * mpmath.sqrt(psi) + zb * mpmath.sqrt(psi - d * d)) ** 2 / d**2
        mcn_n.append({"p_b": pb, "p_c": pc, "alpha": alpha, "power": power, "n": int(mpmath.ceil(n))})

    ni_power = []
    for pb, pc, margin, n, alpha in [(0.02, 0.02, 0.05, 200, 0.05), (0.05, 0.03, 0.1, 150, 0.05), (0.01, 0.04, 0.02, 120, 0.025), (0.1, 0.1, 0.05, 1000, 0.05)]:
        w0, w = ni_spreads(pb, pc, margin)
        za = mp_z(1 - mpmath.mpf(alpha))
        delta = mpmath.mpf(pb) - pc
        power = mp_phi((mpmath.sqrt(n) * (margin - delta) - za * w0) / w)
        ni_power.append({"p_b": pb, "p_c": pc, "margin": margin, "n": n, "alpha": alpha, "power": fl(power)})
    ni_n = []
    for pb, pc, margin, alpha, power in [
        (0.0, 0.0, 0.05, 0.05, 0.8), (0.0, 0.0, 0.02, 0.05, 0.8), (0.0, 0.0, 0.01, 0.05, 0.8),
        (0.02, 0.02, 0.05, 0.05, 0.8), (0.05, 0.03, 0.1, 0.05, 0.9), (0.01, 0.04, 0.02, 0.025, 0.8),
    ]:
        w0, w = ni_spreads(pb, pc, margin)
        za, zb = mp_z(1 - mpmath.mpf(alpha)), mp_z(power)
        delta = mpmath.mpf(pb) - pc
        n = ((za * w0 + zb * w) / (margin - delta)) ** 2
        ni_n.append({"p_b": pb, "p_c": pc, "margin": margin, "alpha": alpha, "power": power, "n": int(mpmath.ceil(n))})
    # Worked numbers of research/stats-guard-calibration.md §4.2: n >= z^2 (1-M)/M.
    assert [r["n"] for r in ni_n[:3]] == [52, 133, 268]

    # Miller (2024) eq. 9/10 with omega^2 = 1/9, sigma^2 = 1/6 (MDE table of
    # research/stats-guard-calibration.md §1.7).
    mde = []
    z = stats.norm.ppf(0.975) + stats.norm.ppf(0.8)
    for n in (20, 50, 100, 200, 500):
        for k in (1, 3, 5, 10):
            variance = 1 / 9 + 2 * (1 / 6) / k
            mde.append({"n": n, "k": k, "variance": variance, "mde": fl(z * math.sqrt(variance / n))})
    sample_size = []
    for delta in (0.05, 0.1, 0.2):
        for k in (1, 3, 5, 10):
            variance = 1 / 9 + 2 * (1 / 6) / k
            sample_size.append({"delta": delta, "k": k, "variance": variance, "n": math.ceil(z**2 * variance / delta**2)})

    write(
        "power",
        {
            "two_proportion": "statsmodels NormalIndPower with proportion_effectsize (Cohen's h); n = ceil(solve_power)",
            "mcnemar": "mpmath, Connor (1987) Biometrics 43:207-211 normal approximation",
            "noninferiority": "mpmath, Nam (1997) / NCSS PASS correlated-proportions non-inferiority score-test approximation; first three rows assert the research worked numbers 52/133/268",
            "mde, sample_size": "scipy.stats.norm, Miller (2024) eq. 9-10 with omega^2=1/9, sigma^2=1/6",
        },
        {
            "two_proportion_power": two_prop,
            "two_proportion_n": two_prop_n,
            "mcnemar_power": mcn,
            "mcnemar_n": mcn_n,
            "noninferiority_power": ni_power,
            "noninferiority_n": ni_n,
            "mde": mde,
            "sample_size": sample_size,
        },
    )


# ── classifier metrics ────────────────────────────────────────────────────


def classifier_fixture():
    rng = np.random.default_rng(7)
    sets = []
    labels = rng.random(60) < 0.4
    scores = np.round(np.where(labels, rng.normal(0.65, 0.2, 60), rng.normal(0.4, 0.2, 60)), 1)
    sets.append((scores, labels))
    labels2 = rng.random(200) < 0.15
    scores2 = np.round(np.where(labels2, rng.beta(5, 2, 200), rng.beta(2, 5, 200)), 3)
    sets.append((scores2, labels2))
    sets.append((np.array([0.5, 0.5, 0.5, 0.5]), np.array([True, False, True, False])))

    out = []
    for scores, labels in sets:
        y = labels.astype(int)
        s = scores.astype(float)
        fpr, tpr, thr = skm.roc_curve(y, s, drop_intermediate=False)
        roc = [
            {"threshold": None if math.isinf(t) else fl(t), "tpr": fl(a), "fpr": fl(b)}
            for t, a, b in zip(thr, tpr, fpr)
        ]
        recall_at = []
        for max_fpr in (0.0, 0.01, 0.05, 0.1, 0.3):
            ok = [p for p in roc if p["fpr"] <= max_fpr]
            best = max(ok, key=lambda p: p["tpr"])  # first max = highest threshold
            recall_at.append({"max_fpr": max_fpr, "recall": best["tpr"], "fpr": best["fpr"], "threshold": best["threshold"]})

        sweep = []
        for t in sorted(set(s.tolist()), reverse=True):
            pred = (s >= t).astype(int)
            tn, fp, fn, tp = skm.confusion_matrix(y, pred, labels=[0, 1]).ravel()
            f2 = skm.fbeta_score(y, pred, beta=2.0, zero_division=0.0)
            sweep.append({"threshold": t, "tp": int(tp), "fp": int(fp), "tn": int(tn), "fn": int(fn), "f2": fl(f2)})

        costs = []
        for cost_fp, cost_fn, prevalence in ((1.0, 1.0, None), (1.0, 10.0, None), (1.0, 20.0, 0.01), (5.0, 1.0, 0.3)):
            pi = y.mean() if prevalence is None else prevalence
            best = None
            for p in roc:
                cost = cost_fn * pi * (1 - p["tpr"]) + cost_fp * (1 - pi) * p["fpr"]
                if best is None or cost < best["expected_cost"]:
                    best = {"threshold": p["threshold"], "expected_cost": fl(cost)}
            costs.append({"cost_fp": cost_fp, "cost_fn": cost_fn, "prevalence": prevalence, **best})

        out.append(
            {
                "scores": s.tolist(),
                "labels": labels.tolist(),
                "roc_auc": fl(skm.roc_auc_score(y, s)),
                "mann_whitney_auc": fl(stats.mannwhitneyu(s[labels], s[~labels]).statistic / (labels.sum() * (~labels).sum())),
                "average_precision": fl(skm.average_precision_score(y, s)),
                "roc_curve": roc,
                "recall_at_fpr": recall_at,
                "threshold_sweep": sweep,
                "cost_weighted": costs,
            }
        )

    metrics_rows = []
    for tp, fp, tn, fn in [(8, 2, 85, 5), (50, 10, 30, 10), (1, 0, 99, 0), (0, 3, 10, 4)]:
        y = [1] * tp + [0] * fp + [0] * tn + [1] * fn
        pred = [1] * tp + [1] * fp + [0] * tn + [0] * fn
        p, r, _, _ = skm.precision_recall_fscore_support(y, pred, average="binary", zero_division=0.0)
        metrics_rows.append(
            {
                "tp": tp, "fp": fp, "tn": tn, "fn": fn,
                "precision": fl(p), "recall": fl(r),
                "f1": fl(skm.f1_score(y, pred, zero_division=0.0)),
                "f05": fl(skm.fbeta_score(y, pred, beta=0.5, zero_division=0.0)),
                "accuracy": fl(skm.accuracy_score(y, pred)),
            }
        )

    ppv = []
    for tpr, fpr, prev in [(0.9, 0.05, 0.01), (0.97, 0.01, 0.001), (0.5, 0.5, 0.5), (0.8, 0.1, 0.44)]:
        ppv.append(
            {
                "tpr": tpr, "fpr": fpr, "prevalence": prev,
                "ppv": tpr * prev / (tpr * prev + fpr * (1 - prev)),
                "npv": (1 - fpr) * (1 - prev) / ((1 - fpr) * (1 - prev) + (1 - tpr) * prev),
            }
        )

    write(
        "classifier",
        {
            "roc_auc": "sklearn.metrics.roc_auc_score; scipy.stats.mannwhitneyu U/(n1*n2)",
            "average_precision": "sklearn.metrics.average_precision_score",
            "roc_curve, recall_at_fpr": "sklearn.metrics.roc_curve(drop_intermediate=False); max TPR with FPR <= target, highest threshold on ties",
            "threshold_sweep": "sklearn.metrics.confusion_matrix / fbeta_score(beta=2) at each distinct score",
            "cost_weighted": "brute force over the sklearn ROC points: cost_fn*pi*(1-TPR) + cost_fp*(1-pi)*FPR, first minimum",
            "metrics": "sklearn precision_recall_fscore_support / f1_score / fbeta_score(beta=0.5) / accuracy_score",
            "prevalence_adjusted": "closed form PPV/NPV (Bayes' rule); research example TPR 0.9, FPR 0.05, pi 0.01 -> PPV 0.154",
        },
        {"sets": out, "metrics": metrics_rows, "prevalence_adjusted": ppv},
    )


if __name__ == "__main__":
    special_fixture()
    descriptives_fixture()
    proportions_fixture()
    pass_k_fixture()
    hypothesis_fixture()
    power_fixture()
    classifier_fixture()
