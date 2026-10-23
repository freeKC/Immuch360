/* global ENACT_PACK_ISOMORPHIC */
import './polyfills';
import React from 'react';
import {createRoot, hydrateRoot} from 'react-dom/client';

import App from './App/App';
import {loadLocale} from './immuch360/i18n';
import {startErrorLog} from './immuch360/diagnostics/errorLog';
import {isTizen} from './platform/detect';
import {addTizenKeymap} from './platform/keymap';
import {registerTizenKeys} from './platform/tizen';

const appElement = <App />;

if (typeof window !== 'undefined') {
	// Immuch360: the errors and policy blocks of the About page from the start; the Samsung Back and keyboard keys in
	// Enact's keymap (harmless on webOS); on a Samsung TV, the remote keys the app uses, asked for before the first render
	startErrorLog();
	addTizenKeymap();
	if (isTizen()) registerTizenKeys();
	const rootElement = document.getElementById('root');
	if (rootElement) {
		if (ENACT_PACK_ISOMORPHIC) {
			hydrateRoot(rootElement, appElement);
		} else {
			// Immuch360: the texts of the TV's language are read before the first render (English on any error)
			const render = () => createRoot(rootElement).render(appElement);
			loadLocale().then(render, render);
		}
	}
}

export default appElement;
