#!/usr/bin/env node
// Immuch360: lets the node test runner import the TypeScript of src/ (node --import ./tools/ts-hooks.mjs --test).
// TypeScript files are turned into JavaScript by esbuild (already used by tools/transpile-legacy.mjs), imports without
// an extension find their .ts or .tsx file as webpack does, and JSON files load as modules. Only the pure modules of
// src/ (no JSX, no LESS, no Enact) are meant to be loaded this way.

import {registerHooks} from 'node:module';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {transformSync} from 'esbuild';

const EXTENSIONS = ['.ts', '.tsx', '/index.ts'];

registerHooks({
	resolve(specifier, context, nextResolve) {
		try {
			return nextResolve(specifier, context);
		} catch (error) {
			const relative = specifier.startsWith('./') || specifier.startsWith('../');
			if (!relative || (error?.code !== 'ERR_MODULE_NOT_FOUND' && error?.code !== 'ERR_UNSUPPORTED_DIR_IMPORT')) throw error;
			for (const extension of EXTENSIONS) {
				try {
					return nextResolve(specifier + extension, context);
				} catch {
					// the next extension
				}
			}
			throw error;
		}
	},
	load(url, context, nextLoad) {
		if (/\.(ts|tsx|mts)$/.test(url)) {
			const path = fileURLToPath(url);
			const {code} = transformSync(readFileSync(path, 'utf8'), {
				loader: url.endsWith('.tsx') ? 'tsx' : 'ts',
				format: 'esm',
				target: 'node22',
				sourcefile: path,
				sourcemap: 'inline',
			});
			return {format: 'module', source: code, shortCircuit: true};
		}
		if (url.endsWith('.json') && url.startsWith('file:')) {
			return {format: 'module', source: `export default ${readFileSync(fileURLToPath(url), 'utf8')};`, shortCircuit: true};
		}
		return nextLoad(url, context);
	},
});
