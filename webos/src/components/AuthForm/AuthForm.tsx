import React, {useCallback, useRef, useState} from 'react';
import Button from '@enact/sandstone/Button';
import TabLayout, {Tab} from '@enact/sandstone/TabLayout';
import {ErrorMessage} from '../ErrorMessage';
import {FieldRow} from '../FieldRow/FieldRow';
import {UrlInput} from '../UrlInput/UrlInput';
import {PairingTab} from './PairingTab';
import {PrivacyPolicyButton} from '../../immuch360/privacy/PrivacyPolicy';
import {AuthMethod, type AuthSubmitResult, type AuthFormPayload} from '../../api/types';
import type {PairingDriver, PairedAccountResult} from '../../pairing/types';
import css from './AuthForm.module.less';
import {t} from '../../immuch360/i18n';

// Canonical auth-attempt types live in api/types; re-exported here for the form's consumers.
export type {AuthSubmitResult, AuthFormPayload};

interface AuthFormProps {
	initialUrl: string;
	onSubmit: (payload: AuthFormPayload) => Promise<AuthSubmitResult>;
	onBack?: () => void;
	pairingDriver?: PairingDriver | null;
	onPairedLogin?: (result: PairedAccountResult) => Promise<AuthSubmitResult>;
}

const LabeledField: React.FC<{label: string; children: React.ReactNode}> = ({label, children}) => (
	<div className={css.field}>
		<label className={css.label}>{label}</label>
		{children}
	</div>
);

export const AuthForm: React.FC<AuthFormProps> = ({initialUrl, onSubmit, onBack, pairingDriver, onPairedLogin}) => {
	const [url, setUrl] = useState(initialUrl);
	const [email, setEmail] = useState('');
	const [password, setPassword] = useState('');
	const [apiKey, setApiKey] = useState('');
	const [error, setError] = useState('');
	const [submitting, setSubmitting] = useState(false);
	const [tabIndex, setTabIndex] = useState(0);
	const userNavigatedRef = useRef(false);

	const submit = useCallback(
		async (payload: AuthFormPayload) => {
			setError('');
			setSubmitting(true);
			try {
				const result = await onSubmit(payload);
				if (!result.success) setError(result.errorMessage);
			} finally {
				setSubmitting(false);
			}
		},
		[onSubmit],
	);

	const submitCreds = useCallback(() => {
		if (!url || !email || !password) {
			setError(t('webos_fill_all_fields'));
			return;
		}
		void submit({method: AuthMethod.USER_CREDENTIALS, baseUrl: url, email, password});
	}, [url, email, password, submit]);

	const submitApi = useCallback(() => {
		if (!url || !apiKey) {
			setError(t('webos_enter_url_and_api_key'));
			return;
		}
		void submit({method: AuthMethod.API_KEY, baseUrl: url, apiKey});
	}, [url, apiKey, submit]);

	const handleTabSelect = useCallback((event: {index?: number}) => {
		userNavigatedRef.current = true;
		if (typeof event.index === 'number') setTabIndex(event.index);
	}, []);

	// Broken pairing service on the default tab would strand the user on an
	// error screen: fall back to Email unless they already picked a tab.
	const handlePairingStartFailed = useCallback(() => {
		if (!userNavigatedRef.current) setTabIndex(1);
	}, []);

	const tabs = [];
	if (pairingDriver && onPairedLogin) {
		tabs.push(
			<Tab title={t('webos_phone')} icon="mobile" tabKey="phone" key="phone">
				{tabIndex === 0 ? (
					<PairingTab
						driver={pairingDriver}
						suggestedUrl={url}
						onPaired={onPairedLogin}
						onStartFailed={handlePairingStartFailed}
					/>
				) : null}
			</Tab>,
		);
	}
	tabs.push(
		<Tab title={t('email')} icon="profile" tabKey="creds" key="creds">
			<div className={css.tabContent}>
				<LabeledField label={t('server_info_box_server_url')}>
					<UrlInput
						value={url}
						onChange={setUrl}
						disabled={submitting}
						placeholder="http(s)://…"
						autoFocus
					/>
				</LabeledField>
				<LabeledField label={t('email')}>
					<FieldRow
						value={email}
						onChange={setEmail}
						placeholder={t('email')}
						disabled={submitting}
						clearLabel={t('clear_value')}
					/>
				</LabeledField>
				<LabeledField label={t('password')}>
					<FieldRow
						value={password}
						onChange={setPassword}
						type="password"
						placeholder={t('password')}
						disabled={submitting}
						clearLabel={t('clear_value')}
					/>
				</LabeledField>
				<div className={css.actions}>
					<Button onClick={submitCreds} disabled={submitting} backgroundOpacity="opaque">
						{submitting ? t('webos_connecting') : t('webos_connect')}
					</Button>
				</div>
			</div>
		</Tab>,
	);
	tabs.push(
		<Tab title={t('api_key')} icon="lock" tabKey="apikey" key="apikey">
			<div className={css.tabContent}>
				<LabeledField label={t('server_info_box_server_url')}>
					<UrlInput
						value={url}
						onChange={setUrl}
						disabled={submitting}
						placeholder="http(s)://…"
					/>
				</LabeledField>
				<LabeledField label={t('api_key')}>
					<FieldRow
						value={apiKey}
						onChange={setApiKey}
						placeholder={t('api_key')}
						disabled={submitting}
						clearLabel={t('clear_value')}
					/>
				</LabeledField>
				<div className={css.actions}>
					<Button onClick={submitApi} disabled={submitting} backgroundOpacity="opaque">
						{submitting ? t('webos_connecting') : t('webos_connect')}
					</Button>
				</div>
			</div>
		</Tab>,
	);

	return (
		<div className={css.root}>
			{onBack ? (
				<Button className={css.backBtn} size="small" icon="arrowsmallleft" onClick={onBack}>
					{t('back')}
				</Button>
			) : null}

			<div className={css.form}>
				<TabLayout className={css.layout} orientation="vertical" index={tabIndex} onSelect={handleTabSelect}>
					{tabs}
				</TabLayout>

				<ErrorMessage message={error} className={css.error} />
				<PrivacyPolicyButton className={css.privacy} />
			</div>
		</div>
	);
};
