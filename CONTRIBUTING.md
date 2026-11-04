# Contributing

Send pull requests against `main`. The CI check must pass.

## Patch format

Patches follow the kernel's
[submitting-patches](https://docs.kernel.org/process/submitting-patches.html)
rules and its guidance on
[AI assistance](https://docs.kernel.org/process/coding-assistants.html),
with two deliberate differences:

- **No `Signed-off-by` on our patches.** The DCO needs a human who can
  vouch for the code, and nobody can for AI-written code. So the patches
  are not upstreamable as they are.
- **`Assisted-by: LLM [tool...]`** once per patch. List analysis tools
  only when used (coccinelle, sparse), not git, gcc or editors.

## Our patches

```
From: Norman Herms <dockseed@proton.me>
Subject: [PATCH] <subsystem>: <what it does, imperative>

<What goes wrong on the hardware.>

<What the change does and why it is correct.>

<What it leaves out, if anything.>

Tested on Radxa Cubie A7S: <what was run and what was seen>.

Assisted-by: LLM
```

- No `Tested-by` or `Reviewed-by`: both name a person. The test goes into
  the "Tested on" line.
- Technical content only: no logs, no debugging history, no references
  outside this repository. A number is fine where it shows the behaviour
  the patch is about.
- As short as the change allows. A long description often means the
  patch should be split.
- Wrap at 75 columns. Subject prefix as for the files touched.

## Patches by other authors

Kept as posted, or as the maintainer applied it. Tags given on the list
may be added, as `b4` does; nothing else changes. If we had to adapt one,
a note goes before the tags. If the assistant made the change,
`Assisted-by: LLM` goes after them:

```
[ adapted to <kernel version>: <what changed and why> ]
Signed-off-by: <original author>
Assisted-by: LLM
```

## Series

One directory in `patches/` per upstream series, as it was or would be
sent. Order in `patches/series`: bindings, drivers, device tree, then
`arm64: defconfig`. Other authors' series first, then ours. A comment
above each series gives author, version, upstream state and lore link.
Once a series is in the kernel we build on, its directory goes.

## Kernel configuration

Each series that needs an option ends with a patch
`arm64: defconfig: Enable <what>`. Options are modules
(`=m`) unless the board cannot boot without them or the driver has no
device that would load a module. Distribution options (firewall, zram,
debug tools) do not belong here.

## Mainline rules

- Mainline frameworks only: clocks in `drivers/clk/sunxi-ng/`, pins in
  `drivers/pinctrl/sunxi/`, everything else in its subsystem. No `#ifdef`
  per SoC or board.
- Vendor code is a reference, not a source. A value from it is a hint to
  verify. A patch based on the vendor kernel says where it differs.
- Every new `compatible` has a dt-schema binding, in a patch before its
  users. Run `make dt_binding_check` and `make dtbs_check` before you
  send; they should report nothing new
  ([maintainer-soc](https://docs.kernel.org/process/maintainer-soc.html),
  [bindings](https://docs.kernel.org/devicetree/bindings/submitting-patches.html)).
  The CI does not run them.
- SoC in `sun60i-a733.dtsi`, the board in `sun60i-a733-cubie-a7s.dts`.
- A device tree change that older kernels cannot handle says so
  ([ABI](https://docs.kernel.org/devicetree/bindings/ABI.html)).

## Canonical form

Each patch file must be byte-identical to the output of this command
(git 2.47 as in `build-env/`, no `diff.*` or `format.*` settings):

```
git format-patch -1 --stdout --zero-commit --no-signature --abbrev=12 <commit>
```

`scripts/patch-check.py` applies the series to the pristine tarball,
exports each commit again and reports any byte that differs. It also
checks the tag rules, runs `checkpatch.pl --strict` on our patches and
looks up every upstream commit they name in torvalds/linux on
git.kernel.org: the id must name one commit, and a quoted subject must
be its subject. See the README for how to run it.
