package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

SCREEN_SIZE :: 800
ORIGIN :: SCREEN_SIZE / 2
SCALE :: 40.0
GRID_RANGE :: 14

Vec2 :: [2]f32

Shared_State :: struct {
	mu:      sync.Mutex,
	i_hat:   Vec2,
	j_hat:   Vec2,
	changed: bool,
	reset:   bool,
	running: bool,
}

g_state: Shared_State

History_Entry :: struct {
	i_hat:   Vec2, // cumulative basis at this step
	j_hat:   Vec2,
	input_i: Vec2, // the input transformation for this step
	input_j: Vec2,
}

History :: struct {
	entries: [dynamic]History_Entry,
	index:   int,
}

history_init :: proc(h: ^History) {
	append(&h.entries, History_Entry{{1, 0}, {0, 1}, {1, 0}, {0, 1}})
	h.index = 0
}

history_current :: proc(h: ^History) -> History_Entry {
	return h.entries[h.index]
}

history_push :: proc(h: ^History, i_hat, j_hat, input_i, input_j: Vec2) {
	// Truncate forward history if we are not at the end
	if h.index < len(h.entries) - 1 {
		remove_range(&h.entries, h.index + 1, len(h.entries))
	}
	append(&h.entries, History_Entry{i_hat, j_hat, input_i, input_j})
	h.index = len(h.entries) - 1
}

history_push_identity :: proc(h: ^History) {
	history_push(h, {1, 0}, {0, 1}, {1, 0}, {0, 1})
}

history_back :: proc(h: ^History) -> bool {
	if h.index > 0 {
		h.index -= 1
		return true
	}
	return false
}

history_forward :: proc(h: ^History) -> bool {
	if h.index < len(h.entries) - 1 {
		h.index += 1
		return true
	}
	return false
}

Input_Field :: struct {
	buf:         [256]byte,
	len:         int,
	cursor:      int,
	error_buf:   [128]byte,
	error_len:   int,
	error_timer: f32,
}

input_insert_char :: proc(input: ^Input_Field, ch: rune) {
	if input.len >= len(input.buf) { return }
	if ch < 32 || ch > 126 { return }

	if input.cursor < input.len {
		copy(input.buf[input.cursor + 1:input.len + 1], input.buf[input.cursor:input.len])
	}
	input.buf[input.cursor] = byte(ch)
	input.len += 1
	input.cursor += 1
}

input_backspace :: proc(input: ^Input_Field) {
	if input.cursor <= 0 { return }
	copy(input.buf[input.cursor - 1:input.len - 1], input.buf[input.cursor:input.len])
	input.cursor -= 1
	input.len -= 1
}

parse_preset :: proc(text: string) -> (i_hat: Vec2, j_hat: Vec2, ok: bool) {
	switch strings.to_lower(strings.trim_space(text)) {
	case "shear", "shear x", "shear h", "horizontal shear", "h shear":
		return {1, 0}, {1, 1}, true
	case "shear y", "shear v", "vertical shear", "v shear":
		return {1, 1}, {0, 1}, true
	case "rotate 90", "rot 90", "rotate90":
		return {0, -1}, {1, 0}, true
	case "rotate -90", "rot -90", "rotate-90":
		return {0, 1}, {-1, 0}, true
	case "rotate 180", "rot 180", "rotate180":
		return {-1, 0}, {0, -1}, true
	case "rotate 45", "rot 45", "rotate45":
		return {0.7071, -0.7071}, {0.7071, 0.7071}, true
	case "rotate -45", "rot -45", "rotate-45":
		return {0.7071, 0.7071}, {-0.7071, 0.7071}, true
	case "scale 2", "scale2", "zoom 2", "x2":
		return {2, 0}, {0, 2}, true
	case "scale 0.5", "scale half", "zoom 0.5", "x0.5", "scale0.5":
		return {0.5, 0}, {0, 0.5}, true
	case "scale 3", "scale3", "zoom 3", "x3":
		return {3, 0}, {0, 3}, true
	case "flip x", "reflect x", "reflection x":
		return {1, 0}, {0, -1}, true
	case "flip y", "reflect y", "reflection y":
		return {-1, 0}, {0, 1}, true
	case "identity", "id", "reset", "r":
		return {1, 0}, {0, 1}, true
	}
	return {}, {}, false
}

input_submit :: proc(input: ^Input_Field) -> (i_hat, j_hat: Vec2, ok: bool) {
	text := strings.trim_space(string(input.buf[:input.len]))

	// Try preset command first
	if i_hat, j_hat, ok = parse_preset(text); ok {
		input.len = 0
		input.cursor = 0
		input.error_len = 0
		return
	}

	fields := strings.fields(text)
	if len(fields) < 4 {
		copy(input.error_buf[:], "Need 4 numbers: i_x i_y j_x j_y")
		input.error_len = len("Need 4 numbers: i_x i_y j_x j_y")
		input.error_timer = 2.0
		return {}, {}, false
	}

	x1, ok1 := strconv.parse_f32(fields[0])
	y1, ok2 := strconv.parse_f32(fields[1])
	x2, ok3 := strconv.parse_f32(fields[2])
	y2, ok4 := strconv.parse_f32(fields[3])
	if !ok1 || !ok2 || !ok3 || !ok4 {
		copy(input.error_buf[:], "Invalid numbers")
		input.error_len = len("Invalid numbers")
		input.error_timer = 2.0
		return {}, {}, false
	}

	input.len = 0
	input.cursor = 0
	input.error_len = 0
	return {x1, y1}, {x2, y2}, true
}

input_thread_proc :: proc(data: rawptr) {
	state := cast(^Shared_State)data
	buf: [1024]byte

	for state.running {
		fmt.print("> ")
		n, read_err := os.read(os.stdin, buf[:])
		if read_err != nil || n == 0 {
			continue
		}

		input := strings.trim_space(string(buf[:n]))
		if input == "quit" || input == "exit" || input == "q" {
			sync.mutex_lock(&state.mu)
			state.running = false
			sync.mutex_unlock(&state.mu)
			return
		}
		if input == "reset" || input == "r" {
			sync.mutex_lock(&state.mu)
			state.reset = true
			sync.mutex_unlock(&state.mu)
			fmt.println("Reset to identity matrix.")
			continue
		}

		// Try preset command
		if i_hat, j_hat, ok := parse_preset(input); ok {
			sync.mutex_lock(&state.mu)
			state.i_hat = i_hat
			state.j_hat = j_hat
			state.changed = true
			sync.mutex_unlock(&state.mu)
			fmt.printf("Input: i-hat = (%.2f, %.2f), j-hat = (%.2f, %.2f) (composed with current)\n", i_hat.x, i_hat.y, j_hat.x, j_hat.y)
			continue
		}

		fields := strings.fields(input)
		if len(fields) >= 4 {
			x1, ok1 := strconv.parse_f32(fields[0])
			y1, ok2 := strconv.parse_f32(fields[1])
			x2, ok3 := strconv.parse_f32(fields[2])
			y2, ok4 := strconv.parse_f32(fields[3])
			if ok1 && ok2 && ok3 && ok4 {
				sync.mutex_lock(&state.mu)
				state.i_hat = {x1, y1}
				state.j_hat = {x2, y2}
				state.changed = true
				sync.mutex_unlock(&state.mu)
				fmt.printf("Input: i-hat = (%.2f, %.2f), j-hat = (%.2f, %.2f) (composed with current)\n", x1, y1, x2, y2)
			} else {
				fmt.println("Error: could not parse one or more values as numbers.")
				fmt.println("Hint: 4 numbers separated by spaces, e.g. 1 0 1 1")
			}
		} else {
			fmt.println("Error: expected 4 numbers (i_x i_y j_x j_y).")
			fmt.println("Hint: 4 numbers separated by spaces, e.g. 1 0 1 1")
		}
	}
}

main :: proc() {
	g_state.i_hat = {1, 0}
	g_state.j_hat = {0, 1}
	g_state.running = true

	fmt.println("=== Linear Transform Visualizer ===")
	fmt.println("Each input is composed (stacked) with the current transform.")
	fmt.println("Format: i_x i_y j_x j_y    Example: 1 0 1 1")
	fmt.println("Presets: shear, shear y, rotate 90, scale 2, flip x, ...")
	fmt.println("Type 'reset' or 'r' to return to identity.")
	fmt.println("Type 'quit', 'exit', or 'q' to stop.")

	input_thread := thread.create_and_start_with_data(
		&g_state,
		input_thread_proc,
		nil,
		thread.Thread_Priority.Normal,
		true,
	)

	rl.InitWindow(SCREEN_SIZE, SCREEN_SIZE, "Linear Transform: i-hat & j-hat")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	history: History
	history_init(&history)

	current_i := Vec2{1, 0}
	current_j := Vec2{0, 1}
	target_i := Vec2{1, 0}
	target_j := Vec2{0, 1}
	input: Input_Field
	input_focused := true

	for !rl.WindowShouldClose() && g_state.running {
		if sync.mutex_guard(&g_state.mu) {
			if g_state.reset {
				history_push_identity(&history)
				g_state.reset = false
			} else if g_state.changed {
				entry := history_current(&history)
				new_i := transform(g_state.i_hat, entry.i_hat, entry.j_hat)
				new_j := transform(g_state.j_hat, entry.i_hat, entry.j_hat)
				history_push(&history, new_i, new_j, g_state.i_hat, g_state.j_hat)
				g_state.changed = false
			}
		}

		if handle_nav_buttons(&history) {
			// current will lerp to the newly selected history entry below
		}

		entry := history_current(&history)
		target_i = entry.i_hat
		target_j = entry.j_hat

		current_i = lerp_vec2(current_i, target_i, 0.1)
		current_j = lerp_vec2(current_j, target_j, 0.1)

		if input.error_timer > 0 {
			input.error_timer -= rl.GetFrameTime()
			if input.error_timer < 0 {
				input.error_timer = 0
				input.error_len = 0
			}
		}

		if input_focused {
			for {
				ch := rl.GetCharPressed()
				if ch == 0 { break }
				input_insert_char(&input, ch)
			}

			if rl.IsKeyPressed(rl.KeyboardKey.BACKSPACE) {
				input_backspace(&input)
			}

			if rl.IsKeyPressed(rl.KeyboardKey.ENTER) {
				text := strings.trim_space(string(input.buf[:input.len]))
				if text == "reset" || text == "r" {
					sync.mutex_lock(&g_state.mu)
					g_state.reset = true
					sync.mutex_unlock(&g_state.mu)
					input.len = 0
					input.cursor = 0
					fmt.println("Reset to identity matrix.")
				} else {
					i_hat, j_hat, ok := input_submit(&input)
					if ok {
						sync.mutex_lock(&g_state.mu)
						g_state.i_hat = i_hat
						g_state.j_hat = j_hat
						g_state.changed = true
						sync.mutex_unlock(&g_state.mu)
						fmt.printf("Input: i-hat = (%.2f, %.2f), j-hat = (%.2f, %.2f) (composed with current)\n", i_hat.x, i_hat.y, j_hat.x, j_hat.y)
					}
				}
			}
		}

		rl.BeginDrawing()
		defer rl.EndDrawing()

		rl.ClearBackground({10, 10, 20, 255})

		draw_original_grid()
		draw_transformed_grid(current_i, current_j)
		draw_axes()
		draw_basis_vectors(current_i, current_j)
		draw_info(&history, current_i, current_j)
		draw_input_field(&input, input_focused)
		draw_nav_buttons(&history)
	}

	if input_thread != nil {
		thread.destroy(input_thread)
	}
	delete(history.entries)
}

math_to_screen :: proc(v: Vec2) -> rl.Vector2 {
	return {
		ORIGIN + v.x * SCALE,
		ORIGIN - v.y * SCALE,
	}
}

transform :: proc(v, i_hat, j_hat: Vec2) -> Vec2 {
	return v.x * i_hat + v.y * j_hat
}

lerp_vec2 :: proc(a, b: Vec2, t: f32) -> Vec2 {
	diff := b - a
	if abs(diff.x) < 0.001 && abs(diff.y) < 0.001 {
		return b
	}
	return a + diff * t
}

compute_transformed_grid_range :: proc(i_hat, j_hat: Vec2) -> int {
	// Visible logical region is [-10, 10] x [-10, 10] (SCREEN_SIZE/2 / SCALE = 10).
	// We want T([-R, R]^2) to contain this square, so R = max |T^{-1}(corner)|.
	a := i_hat.x
	b := j_hat.x
	c := i_hat.y
	d := j_hat.y
	det := a*d - b*c

	if abs(det) < 0.001 {
		return 50 // Degenerate transformation: fall back to a large range.
	}

	inv_det := 1.0 / det
	visible_half := f32(SCREEN_SIZE / 2) / SCALE // 10.0
	corners := [?]Vec2{
		{ visible_half,  visible_half},
		{ visible_half, -visible_half},
		{-visible_half,  visible_half},
		{-visible_half, -visible_half},
	}

	max_r: f32 = 0.0
	for corner in corners {
		px := inv_det * ( d * corner.x - b * corner.y)
		py := inv_det * (-c * corner.x + a * corner.y)
		max_r = max(max_r, abs(px))
		max_r = max(max_r, abs(py))
	}

	r := int(max_r * 1.3) + 1
	if r < GRID_RANGE { r = GRID_RANGE }
	if r > 120 { r = 120 }
	return r
}

draw_axes :: proc() {
	origin := math_to_screen({0, 0})
	x_end := math_to_screen({f32(GRID_RANGE), 0})
	y_end := math_to_screen({0, f32(GRID_RANGE)})
	x_neg := math_to_screen({-f32(GRID_RANGE), 0})
	y_neg := math_to_screen({0, -f32(GRID_RANGE)})

	rl.DrawLineV(origin, x_end, {200, 200, 200, 255})
	rl.DrawLineV(origin, x_neg, {200, 200, 200, 255})
	rl.DrawLineV(origin, y_end, {200, 200, 200, 255})
	rl.DrawLineV(origin, y_neg, {200, 200, 200, 255})
}

draw_original_grid :: proc() {
	color := rl.Color{60, 60, 70, 255}
	for i := -GRID_RANGE; i <= GRID_RANGE; i += 1 {
		a := math_to_screen({f32(i), -f32(GRID_RANGE)})
		b := math_to_screen({f32(i), f32(GRID_RANGE)})
		rl.DrawLineV(a, b, color)

		a = math_to_screen({-f32(GRID_RANGE), f32(i)})
		b = math_to_screen({f32(GRID_RANGE), f32(i)})
		rl.DrawLineV(a, b, color)
	}
}

draw_transformed_grid :: proc(i_hat, j_hat: Vec2) {
	color := rl.Color{80, 140, 200, 255}
	r := compute_transformed_grid_range(i_hat, j_hat)
	for i := -r; i <= r; i += 1 {
		a := math_to_screen(transform({f32(i), -f32(r)}, i_hat, j_hat))
		b := math_to_screen(transform({f32(i), f32(r)}, i_hat, j_hat))
		rl.DrawLineV(a, b, color)

		a = math_to_screen(transform({-f32(r), f32(i)}, i_hat, j_hat))
		b = math_to_screen(transform({f32(r), f32(i)}, i_hat, j_hat))
		rl.DrawLineV(a, b, color)
	}
}

draw_arrow :: proc(from, to: rl.Vector2, color: rl.Color, thickness: f32 = 2.0) {
	rl.DrawLineEx(from, to, thickness, color)

	dir := to - from
	len := math.sqrt(dir.x * dir.x + dir.y * dir.y)
	if len < 0.001 {
		return
	}
	dir /= len

	// In screen space, up is -y, so perpendicular is {-dir.y, dir.x}
	perp := rl.Vector2{-dir.y, dir.x}
	arrow_len :: 12.0
	arrow_width :: 6.0

	tip1 := to - arrow_len * dir + arrow_width * perp
	tip2 := to - arrow_len * dir - arrow_width * perp

	rl.DrawLineEx(to, tip1, thickness, color)
	rl.DrawLineEx(to, tip2, thickness, color)
}

draw_basis_vectors :: proc(i_hat, j_hat: Vec2) {
	origin := math_to_screen({0, 0})
	i_end := math_to_screen(i_hat)
	j_end := math_to_screen(j_hat)

	draw_arrow(origin, i_end, {255, 80, 80, 255}, 3.0)
	draw_arrow(origin, j_end, {80, 255, 120, 255}, 3.0)
}

draw_info :: proc(history: ^History, i_hat, j_hat: Vec2) {
	text_color := rl.Color{230, 230, 230, 255}
	matrix_color := rl.Color{200, 200, 255, 255}
	step_color := rl.Color{180, 220, 255, 255}
	rl.DrawText(fmt.ctprintf("i-hat = (%.2f, %.2f)", i_hat.x, i_hat.y), 20, 20, 20, {255, 80, 80, 255})
	rl.DrawText(fmt.ctprintf("j-hat = (%.2f, %.2f)", j_hat.x, j_hat.y), 20, 45, 20, {80, 255, 120, 255})
	rl.DrawText("Blue lines = transformed grid", 20, 75, 18, text_color)
	rl.DrawText("Gray lines = original grid", 20, 95, 18, text_color)

	y: i32 = 120

	// Build chain text: M3 × M2 × M1
	chain_len := history.index
	if chain_len > 0 {
		rl.DrawText("Built from:", 20, y, 16, matrix_color)
		y += 20

		chain_buf: [256]byte
		chain_pos := 0
		for k := chain_len; k >= 1; k -= 1 {
			label := fmt.tprintf("M%d", k)
			copy(chain_buf[chain_pos:], label)
			chain_pos += len(label)
			if k > 1 {
				copy(chain_buf[chain_pos:], " × ")
				chain_pos += 3
			}
		}
		rl.DrawText(fmt.ctprintf("%s", string(chain_buf[:chain_pos])), 20, y, 16, matrix_color)
		y += 25

		// Show each step's input matrix horizontally
		rl.DrawText("Each step matrix:", 20, y, 16, matrix_color)
		y += 18
		col_w: i32 = 110
		for k := 1; k <= chain_len; k += 1 {
			x := 20 + i32(k - 1) * col_w
			rl.DrawText(fmt.ctprintf("M%d:", k), x, y, 14, step_color)
		}
		y += 16
		for k := 1; k <= chain_len; k += 1 {
			x := 20 + i32(k - 1) * col_w
			entry := history.entries[k]
			rl.DrawText(fmt.ctprintf("| %.2f  %.2f |", entry.input_i.x, entry.input_j.x), x, y, 14, step_color)
		}
		y += 16
		for k := 1; k <= chain_len; k += 1 {
			x := 20 + i32(k - 1) * col_w
			entry := history.entries[k]
			rl.DrawText(fmt.ctprintf("| %.2f  %.2f |", entry.input_i.y, entry.input_j.y), x, y, 14, step_color)
		}
		y += 30
	}

	rl.DrawText("Cumulative matrix:", 20, y, 16, matrix_color)
	y += 20
	rl.DrawText(fmt.ctprintf("| %.2f  %.2f |", i_hat.x, j_hat.x), 20, y, 16, matrix_color)
	y += 20
	rl.DrawText(fmt.ctprintf("| %.2f  %.2f |", i_hat.y, j_hat.y), 20, y, 16, matrix_color)
	y += 25

	rl.DrawText("Matrix multiplication:", 20, y, 16, matrix_color)
	y += 20
	rl.DrawText(fmt.ctprintf("[x']   [%.2f  %.2f] [x]", i_hat.x, j_hat.x), 20, y, 16, matrix_color)
	y += 20
	rl.DrawText(fmt.ctprintf("[y'] = [%.2f  %.2f] [y]", i_hat.y, j_hat.y), 20, y, 16, matrix_color)
	y += 25
	rl.DrawText("Component-wise:", 20, y, 16, matrix_color)
	y += 20
	rl.DrawText(fmt.ctprintf("x' = %.2f*x + %.2f*y", i_hat.x, j_hat.x), 20, y, 16, matrix_color)
	y += 20
	rl.DrawText(fmt.ctprintf("y' = %.2f*x + %.2f*y", i_hat.y, j_hat.y), 20, y, 16, matrix_color)
}

draw_input_field :: proc(input: ^Input_Field, focused: bool) {
	box_x: i32 = 150
	box_y: i32 = SCREEN_SIZE - 80
	box_w: i32 = 500
	box_h: i32 = 40
	font_size: i32 = 20

	bg_color := rl.Color{30, 30, 45, 255}
	if focused {
		bg_color = rl.Color{45, 45, 65, 255}
	}
	rl.DrawRectangle(box_x, box_y, box_w, box_h, bg_color)
	border_color := focused ? rl.Color{160, 160, 220, 255} : rl.Color{120, 120, 160, 255}
	rl.DrawRectangleLines(box_x, box_y, box_w, box_h, border_color)

	rl.DrawText("Enter basis vectors / preset and press ENTER:", 150, box_y - 55, 18, rl.Color{220, 220, 240, 255})
	rl.DrawText("Format: i_x i_y j_x j_y  |  Presets: shear, rotate 90, scale 2, flip x", 150, box_y - 33, 16, rl.Color{160, 160, 190, 255})
	rl.DrawText("Each input stacks on the current transform. Type 'reset' to clear.", 150, box_y - 14, 14, rl.Color{140, 140, 170, 255})

	text_x := box_x + 10
	text_y := box_y + (box_h - font_size) / 2
	text := string(input.buf[:input.len])
	if input.len == 0 {
		rl.DrawText("1 0 1 1", text_x, text_y, font_size, rl.Color{120, 120, 140, 255})
	} else {
		rl.DrawText(fmt.ctprintf("%s", text), text_x, text_y, font_size, rl.Color{255, 255, 255, 255})
	}

	if focused {
		cursor_time := rl.GetTime()
		if int(cursor_time * 2) % 2 == 0 {
			display_text := input.len == 0 ? "" : text
			cursor_offset := rl.MeasureText(fmt.ctprintf("%s", display_text), font_size)
			rl.DrawLine(text_x + cursor_offset, text_y, text_x + cursor_offset, text_y + font_size, rl.Color{255, 255, 255, 255})
		}
	}

	if input.error_len > 0 {
		err := string(input.error_buf[:input.error_len])
		err_y := box_y + box_h + 10
		err_w := rl.MeasureText(fmt.ctprintf("%s", err), 20) + 20
		rl.DrawRectangle(140, err_y - 4, err_w, 28, rl.Color{60, 20, 20, 220})
		rl.DrawRectangleLines(140, err_y - 4, err_w, 28, rl.Color{255, 100, 100, 255})
		rl.DrawText(fmt.ctprintf("%s", err), 150, err_y, 20, rl.Color{255, 120, 120, 255})
	}
}

handle_nav_buttons :: proc(h: ^History) -> bool {
	left_rect := rl.Rectangle{100, f32(SCREEN_SIZE - 80), 40, 40}
	right_rect := rl.Rectangle{660, f32(SCREEN_SIZE - 80), 40, 40}
	mouse := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(rl.MouseButton.LEFT)

	if clicked && rl.CheckCollisionPointRec(mouse, left_rect) {
		return history_back(h)
	}
	if clicked && rl.CheckCollisionPointRec(mouse, right_rect) {
		return history_forward(h)
	}
	return false
}

draw_nav_buttons :: proc(h: ^History) {
	button_y: i32 = SCREEN_SIZE - 80
	button_size: i32 = 40
	font_size: i32 = 24

	// Left button
	left_x: i32 = 100
	left_enabled := h.index > 0
	left_bg := left_enabled ? rl.Color{60, 60, 90, 255} : rl.Color{40, 40, 50, 255}
	left_text := left_enabled ? rl.Color{255, 255, 255, 255} : rl.Color{120, 120, 120, 255}
	rl.DrawRectangle(left_x, button_y, button_size, button_size, left_bg)
	rl.DrawRectangleLines(left_x, button_y, button_size, button_size, left_enabled ? rl.Color{160, 160, 220, 255} : rl.Color{80, 80, 90, 255})
	left_text_w := rl.MeasureText("<", font_size)
	rl.DrawText("<", left_x + (button_size - left_text_w) / 2, button_y + (button_size - font_size) / 2, font_size, left_text)

	// Right button
	right_x: i32 = 660
	right_enabled := h.index < len(h.entries) - 1
	right_bg := right_enabled ? rl.Color{60, 60, 90, 255} : rl.Color{40, 40, 50, 255}
	right_text := right_enabled ? rl.Color{255, 255, 255, 255} : rl.Color{120, 120, 120, 255}
	rl.DrawRectangle(right_x, button_y, button_size, button_size, right_bg)
	rl.DrawRectangleLines(right_x, button_y, button_size, button_size, right_enabled ? rl.Color{160, 160, 220, 255} : rl.Color{80, 80, 90, 255})
	right_text_w := rl.MeasureText(">", font_size)
	rl.DrawText(">", right_x + (button_size - right_text_w) / 2, button_y + (button_size - font_size) / 2, font_size, right_text)

	// Step counter
	step_text := fmt.ctprintf("Step %d / %d", h.index + 1, len(h.entries))
	step_w := rl.MeasureText(step_text, 16)
	rl.DrawText(step_text, SCREEN_SIZE / 2 - step_w / 2, button_y + button_size + 8, 16, rl.Color{180, 180, 210, 255})
}
