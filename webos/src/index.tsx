/* global ENACT_PACK_ISOMORPHIC */
import './polyfills';
import React from 'react';
import {createRoot, hydrateRoot} from 'react-dom/client';

import App from './App/App';
import {loadLocale} from './immuch360/i18n';

const appElement = <App />;

if (typeof window !== 'undefined') {
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
