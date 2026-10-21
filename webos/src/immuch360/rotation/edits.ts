// Immuch360: the edits of Immich's photo editor (crop, rotate, mirror) and the quarter turns of the one-key rotation.
//
// The server applies the edits of an asset in their order (PUT /api/assets/{id}/edits). Turning a photo that already
// has edits is appending a rotation; the mirror and the rotations then fold into one mirror and one rotation, as the
// editor reads them. Port of normalizeTransformEdits (mobile/lib/utils/editor.utils.dart, web/src/lib/utils/editor.ts)
// and of composeQuarterTurns of the Flutter app, with the same tests (test/unit/rotation-edits.test.mjs).

export interface CropEdit {
	action: 'crop';
	parameters: {x: number; y: number; width: number; height: number};
}

export interface RotateEdit {
	action: 'rotate';
	parameters: {angle: number};
}

export interface MirrorEdit {
	action: 'mirror';
	parameters: {axis: 'horizontal' | 'vertical'};
}

export type AssetEdit = CropEdit | RotateEdit | MirrorEdit;

/** An affine matrix as the editor writes it: x' = a x + c y + e, y' = b x + d y + f */
export interface Affine {
	a: number;
	b: number;
	c: number;
	d: number;
	e: number;
	f: number;
}

const IDENTITY: Affine = {a: 1, b: 0, c: 0, d: 1, e: 0, f: 0};

function multiply(m: Affine, n: Affine): Affine {
	return {
		a: m.a * n.a + m.c * n.b,
		b: m.b * n.a + m.d * n.b,
		c: m.a * n.c + m.c * n.d,
		d: m.b * n.c + m.d * n.d,
		e: m.a * n.e + m.c * n.f + m.e,
		f: m.b * n.e + m.d * n.f + m.f,
	};
}

function matrixOf(edit: AssetEdit): Affine {
	switch (edit.action) {
		case 'rotate': {
			const angle = (edit.parameters.angle * Math.PI) / 180;
			const cos = Math.cos(angle);
			const sin = Math.sin(angle);
			return {a: cos, b: -sin, c: sin, d: cos, e: 0, f: 0};
		}
		case 'mirror':
			return edit.parameters.axis === 'horizontal' ? {a: -1, b: 0, c: 0, d: 1, e: 0, f: 0} : {a: 1, b: 0, c: 0, d: -1, e: 0, f: 0};
		default:
			return IDENTITY;
	}
}

/** The transform of the edits, the crop aside */
export function affineOfEdits(edits: readonly AssetEdit[]): Affine {
	return edits.reduce((matrix, edit) => multiply(matrix, matrixOf(edit)), IDENTITY);
}

const isCloseToZero = (value: number) => Math.abs(value) < 1e-15;

/** [turns] brought into 0 to 3: 4 quarter turns are no turn, -1 is 3 */
export const normalizeQuarterTurns = (turns: number): number => ((turns % 4) + 4) % 4;

/** The edits as the editor reads them: a rotation (0, 90, 180 or 270) and whether the picture is mirrored vertically */
export function normalizeTransform(edits: readonly AssetEdit[]): {rotation: number; mirrorVertical: boolean} {
	const {a, b, c, d} = affineOfEdits(edits);
	const degrees = ((isCloseToZero(a) ? Math.asin(c) : Math.acos(a)) * 180) / Math.PI;
	return {
		rotation: normalizeQuarterTurns(Math.round(degrees / 90)) * 90,
		mirrorVertical: isCloseToZero(a) ? b === c : a === -d,
	};
}

/** How many quarter turns clockwise the edits turn the picture, 0 to 3, the mirror aside */
export const quarterTurnsOfEdits = (edits: readonly AssetEdit[]): number => normalizeTransform(edits).rotation / 90;

/**
 * The edits once the picture they make is turned by [turns] quarter turns clockwise (negative turns go counter
 * clockwise): what the editor saves after as many presses on "rotate clockwise", in the editor's order, the crop first
 * and untouched, then the mirror, then the rotation. An empty list means no edit at all, which removes them.
 */
export function composeQuarterTurns(edits: readonly AssetEdit[], turns: number): AssetEdit[] {
	const crop = edits.filter((edit): edit is CropEdit => edit.action === 'crop')[0];
	const transform = normalizeTransform(edits);
	const rotation = (((transform.rotation + 90 * turns) % 360) + 360) % 360;
	const composed: AssetEdit[] = [];
	if (crop) composed.push(crop);
	if (transform.mirrorVertical) composed.push({action: 'mirror', parameters: {axis: 'vertical'}});
	if (rotation !== 0) composed.push({action: 'rotate', parameters: {angle: rotation}});
	return composed;
}

/** The edits of the server's answer (GET /api/assets/{id}/edits) without their ids, as PUT takes them; null when one is
 * of a kind this app does not know, which composing would drop */
export function editsFromServer(edits: readonly {action: string; parameters: unknown}[]): AssetEdit[] | null {
	const known: AssetEdit[] = [];
	for (const edit of edits) {
		if (edit.action !== 'crop' && edit.action !== 'rotate' && edit.action !== 'mirror') return null;
		known.push({action: edit.action, parameters: edit.parameters} as AssetEdit);
	}
	return known;
}
