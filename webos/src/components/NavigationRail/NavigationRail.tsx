import React, {useMemo} from 'react';
import Icon from '@enact/sandstone/Icon';
import Marquee, {MarqueeController} from '@enact/sandstone/Marquee';
import {createSpotlightContainer, SpottableButton} from '../../utils/spotlight';
import {NAVIGATION_RAIL_ID} from '../../utils/constants';
import type {View} from '../../types/navigation';
import css from './NavigationRail.module.less';
import {i18nKey, t} from '../../immuch360/i18n';

interface NavigationRailProps {
	activeView: View;
	onNavigate: (view: View) => void;
	onOpenAccount: () => void;
	accountLetter: string;
	accountGradient: string;
}

// Immuch360: labels from the fork's i18n/ files
const NAV_ITEMS: {view: View; icon: string; label: string}[] = [
	{view: 'photos', icon: 'picture', label: i18nKey('photos')},
	{view: 'albums', icon: 'folder', label: i18nKey('albums')},
	{view: 'places', icon: 'location', label: i18nKey('places')},
	{view: 'search', icon: 'search', label: i18nKey('search')},
	{view: 'sources', icon: 'network', label: i18nKey('network_shares')},
	{view: 'about', icon: 'info', label: i18nKey('about')},
];

const RailContainer = createSpotlightContainer({enterTo: 'last-focused'});

// Immuch360: a label longer than the rail ("Network shares", and longer ones in other languages) ends with an ellipsis
// and rolls while its item has the focus (LG's self checklist, item 6: text cut with an ellipsis or rolling)
// (the typings of MarqueeController leave out the config argument that the hoc takes)
const withMarqueeOnFocus = MarqueeController as unknown as (config: {marqueeOnFocus: boolean}, wrapped: typeof SpottableButton) => typeof SpottableButton;
const RailItem = withMarqueeOnFocus({marqueeOnFocus: true}, SpottableButton);

export const NavigationRail: React.FC<NavigationRailProps> = React.memo(({activeView, onNavigate, onOpenAccount, accountLetter, accountGradient}) => {
	const navHandlers = useMemo(
		() => Object.fromEntries(NAV_ITEMS.map(({view}) => [view, () => onNavigate(view)])),
		[onNavigate]
	);

	return (
		// Keep the DOM destination stable, but let Spotlight allocate an ID per mount. During
		// an account switch Enact registers the new rail in render before removing the old one;
		// sharing a Spotlight ID lets the old rail's cleanup unregister the replacement.
		<RailContainer className={css.rail} id={NAVIGATION_RAIL_ID}>
			{NAV_ITEMS.map(({view, icon, label}) => (
				<RailItem
					key={view}
					data-view={view}
					aria-current={activeView === view ? 'page' : undefined}
					className={[css.navItem, activeView === view ? css.active : ''].filter(Boolean).join(' ')}
					onClick={navHandlers[view]}
				>
					<div className={css.iconContainer}>
						<Icon size="tiny">{icon}</Icon>
					</div>
					<Marquee className={css.label} marqueeOn="focus" data-rail-label>
						{t(label)}
					</Marquee>
				</RailItem>
			))}
			<div className={css.spacer} />
			<div className={css.divider} />
			<RailItem className={css.navItem} onClick={onOpenAccount}>
				<div className={css.iconContainer}>
					<span className={css.avatar} style={{background: accountGradient}}>
						{accountLetter}
					</span>
				</div>
				<Marquee className={css.label} marqueeOn="focus">
					{t('account')}
				</Marquee>
			</RailItem>
		</RailContainer>
	);
});

NavigationRail.displayName = 'NavigationRail';
