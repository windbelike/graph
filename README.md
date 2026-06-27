# Linear Transform Visualizer

A small interactive demo written in [Odin](https://odin-lang.org/) with [raylib](https://www.raylib.com/). It visualizes 2D linear transformations by showing how the standard grid and basis vectors change under arbitrary basis vectors.

## Run

Requires the Odin compiler and raylib (raylib is bundled with Odin's `vendor:raylib`).

```bash
# Build
odin build . -out:odin_graph

# Run
./odin_graph

# Or build and run in one step
odin run .
```

## How to use

### Input basis vectors

In the bottom input box of the window, type four numbers separated by spaces:

```text
i_x i_y j_x j_y
```

For example:

```text
1 0 1 1
```

Press **Enter** to apply. The new transformation is **composed** (stacked) with the current one.

### Preset commands

You can also type common transformations directly. These work in both the window input box and the terminal.

| Command | Matrix | Effect |
|---|---|---|
| `shear` or `shear x` | `1 0 1 1` | Horizontal shear |
| `shear y` | `1 1 0 1` | Vertical shear |
| `rotate 90` | `0 -1 1 0` | Rotate 90° counter-clockwise |
| `rotate -90` | `0 1 -1 0` | Rotate 90° clockwise |
| `rotate 180` | `-1 0 0 -1` | Rotate 180° |
| `rotate 45` | `0.707 -0.707 0.707 0.707` | Rotate 45° counter-clockwise |
| `scale 2` | `2 0 0 2` | Uniform scale by 2 |
| `scale 0.5` | `0.5 0 0 0.5` | Uniform scale by 0.5 |
| `scale 3` | `3 0 0 3` | Uniform scale by 3 |
| `flip x` | `1 0 0 -1` | Reflect across x-axis |
| `flip y` | `-1 0 0 1` | Reflect across y-axis |
| `identity` or `id` | `1 0 0 1` | Identity (same as reset) |


### Navigation

- **Left arrow** `<` – go back to the previous transformation state
- **Right arrow** `>` – go forward to the next transformation state
- The bottom counter shows the current step and total number of steps

Both arrow transitions are animated.

### Reset

Type `reset` or `r` in the input box (or terminal) and press **Enter** to add an identity step and return to the standard basis.

### Terminal input

You can also type basis vectors into the terminal where you launched the program. The terminal supports the same format and the `reset`/`quit` commands.

```text
> 1 0 1 1
> 1 1 0 1
> reset
> q
```

### Exit

- Press **ESC**
- Close the window
- Type `quit`, `exit`, or `q`

## What's shown

- **Gray grid** – original standard grid
- **Blue grid** – transformed grid; density is recalculated each frame to fill the screen
- **Red arrow** – transformed i-hat
- **Green arrow** – transformed j-hat
- **Top-left panel** – i-hat/j-hat values, legend, the full transformation chain (`M2 × M1`), each step's input matrix, cumulative matrix, expanded matrix multiplication, and component-wise formula

## Project structure

```text
.
├── main.odin      # Source code
├── .gitignore     # Git ignore rules
└── README.md      # This file
```

## License

Public domain / do whatever you want.
