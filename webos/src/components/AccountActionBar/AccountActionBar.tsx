import React, {useCallback} from 'react';
import Button from '@enact/sandstone/Button';
import css from './AccountActionBar.module.less';
import {t} from '../../immuch360/i18n';

interface Props {
	focusedAccountId: string | null;
	activeAccountId: string | null;
	defaultAccountId: string | null;
	onSwitch: (id: string) => void;
	onSetDefault: (id: string | null) => void;
	onRemove: (id: string) => void;
}

export const AccountActionBar: React.FC<Props> = ({
	focusedAccountId,
	activeAccountId,
	defaultAccountId,
	onSwitch,
	onSetDefault,
	onRemove,
}) => {
	const id = focusedAccountId;
	const isActive = id !== null && id === activeAccountId;
	const isDefault = id !== null && id === defaultAccountId;

	const handleSwitch = useCallback(() => {
		if (id) onSwitch(id);
	}, [id, onSwitch]);
	const handleSetDefault = useCallback(() => {
		onSetDefault(id);
	}, [id, onSetDefault]);
	const handleRemove = useCallback(() => {
		if (id) onRemove(id);
	}, [id, onRemove]);

	if (id === null) return null;

	return (
		<div className={css.bar}>
			{!isActive ? <Button onClick={handleSwitch}>{t('webos_switch')}</Button> : null}
			<Button onClick={handleSetDefault} disabled={isDefault}>
				{t('webos_set_as_default')}
			</Button>
			<Button onClick={handleRemove} backgroundOpacity="transparent">
				{isActive ? t('sign_out') : t('remove')}
			</Button>
		</div>
	);
};
