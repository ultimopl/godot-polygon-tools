@tool
class_name AutoWeightLinAlg
extends RefCounted

## Linear-algebra helpers for the bone-heat solver.
## Pure functions, no editor / scene dependencies.

const EPS := 1e-9


## Build the cotangent Laplacian L (n x n) from a triangulated 2D mesh.
## points: PackedVector2Array of vertex positions (global space).
## tris: PackedInt32Array of triangle indices (multiple of 3).
## Returns an Array[PackedFloat64Array] (dense symmetric matrix).
##
## Convention: for i != j, L[i][j] = 0.5 * (cot a + cot b) over the (up to two)
## triangles sharing edge (i, j). Diagonal L[i][i] = -sum_{j!=i} L[i][j].
## With this sign, L is negative semi-definite, matching the plan equation
## (-L + H) w = H p, which yields a positive-definite system.
static func cotangent_laplacian(points: PackedVector2Array, tris: PackedInt32Array) -> Array:
	var n := points.size()
	var L := []
	L.resize(n)
	for i in n:
		var row := PackedFloat64Array()
		row.resize(n)
		L[i] = row

	var t := 0
	while t + 2 < tris.size():
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		t += 3
		_accumulate_corner(L, points, a, b, c) # angle at a subtends edge (b,c)
		_accumulate_corner(L, points, b, c, a)
		_accumulate_corner(L, points, c, a, b)

	for i in n:
		var s := 0.0
		var row: PackedFloat64Array = L[i]
		for j in n:
			if j != i:
				s += row[j]
		row[i] = -s
	return L


## Add 0.5 * cot(angle at apex) to the off-diagonal entries of edge (p, q).
static func _accumulate_corner(L: Array, points: PackedVector2Array, apex: int, p: int, q: int) -> void:
	var u := points[p] - points[apex]
	var v := points[q] - points[apex]
	var cross := absf(u.x * v.y - u.y * v.x)
	if cross < EPS:
		return
	var dot := u.dot(v)
	var cot := dot / cross
	var w := 0.5 * cot
	L[p][q] += w
	L[q][p] += w


## Solve the dense linear system A x = b via Gaussian elimination with partial
## pivoting. A is Array[PackedFloat64Array] (n x n), b PackedFloat64Array (n).
## A and b are copied internally; inputs are not mutated.
## Returns the solution PackedFloat64Array, or empty on singular matrix.
static func solve(A: Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var n := b.size()
	# Deep copy into an augmented working matrix.
	var m := []
	m.resize(n)
	for i in n:
		var row := PackedFloat64Array()
		row.resize(n + 1)
		var src: PackedFloat64Array = A[i]
		for j in n:
			row[j] = src[j]
		row[n] = b[i]
		m[i] = row

	for col in n:
		# Partial pivot.
		var pivot := col
		var best := absf(m[col][col])
		for r in range(col + 1, n):
			var val := absf(m[r][col])
			if val > best:
				best = val
				pivot = r
		if best < EPS:
			return PackedFloat64Array() # singular
		if pivot != col:
			var tmp: PackedFloat64Array = m[col]
			m[col] = m[pivot]
			m[pivot] = tmp

		var prow: PackedFloat64Array = m[col]
		var pval := prow[col]
		for r in range(col + 1, n):
			var rrow: PackedFloat64Array = m[r]
			var factor := rrow[col] / pval
			if factor == 0.0:
				continue
			for j in range(col, n + 1):
				rrow[j] -= factor * prow[j]

	# Back substitution.
	var x := PackedFloat64Array()
	x.resize(n)
	for i in range(n - 1, -1, -1):
		var row: PackedFloat64Array = m[i]
		var s := row[n]
		for j in range(i + 1, n):
			s -= row[j] * x[j]
		x[i] = s / row[i]
	return x
