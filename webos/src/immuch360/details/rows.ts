// Immuch360: the lines of the details panel of the viewer (Info on the remote, I on a keyboard, or the details button):
// what the timeline knows of the item, and what GET /api/assets/{id} adds once it has answered.

import type {AssetDetails, TimelineAsset} from '../../domain/types';
import {formatAssetDateTime} from '../../utils/FormattingService';
import {currentLocaleTag, t} from '../i18n';

export interface DetailsRow {
	label: string;
	value: string;
}

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB'];

/** A size in bytes the way Immich shows it: 1024 per step, one decimal from KB on */
export function formatBytes(bytes: number, localeTag = currentLocaleTag()): string {
	let value = bytes;
	let unit = 0;
	while (value >= 1024 && unit < UNITS.length - 1) {
		value /= 1024;
		unit++;
	}
	const digits = unit === 0 ? 0 : 1;
	return `${value.toLocaleString(localeTag, {minimumFractionDigits: digits, maximumFractionDigits: digits})} ${UNITS[unit]}`;
}

/** The camera, its make left out when the model already starts with it ("Canon EOS R6", not "Canon Canon EOS R6") */
export function cameraName(make: string | null, model: string | null): string {
	const brand = (make ?? '').trim();
	const name = (model ?? '').trim();
	if (!name) return brand;
	if (!brand || name.toLowerCase().indexOf(brand.toLowerCase()) === 0) return name;
	return `${brand} ${name}`;
}

/** The rows of the panel, those without a value left out */
export function detailsRows(asset: TimelineAsset, details: AssetDetails | null): DetailsRow[] {
	const rows: DetailsRow[] = [];
	const add = (label: string, value: string | null | undefined) => {
		if (value) rows.push({label, value});
	};
	add(t('filename'), details?.originalFileName);
	const {date, time} = formatAssetDateTime(asset.localDateTime);
	add(t('date_and_time'), `${date}, ${time}`);
	if (details?.width && details.height) add(t('resolution'), `${details.width} × ${details.height}`);
	if (details?.fileSize) add(t('file_size'), formatBytes(details.fileSize));
	add(t('camera'), details ? cameraName(details.make, details.model) : null);
	add(t('type'), details?.originalMimeType);
	add(t('location'), [asset.city, asset.country].filter(Boolean).join(', '));
	return rows;
}
