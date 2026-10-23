import React, {useCallback, useContext} from 'react';
import Button from '@enact/sandstone/Button';
import {QueryClientContext} from '@tanstack/react-query';
import {presentError} from '../utils/presentError';
import {useOnline} from '../hooks/useOnline';
import css from './QueryStateView.module.less';
import {t} from '../immuch360/i18n';

interface QueryStateViewProps {
	isLoading: boolean;
	error: unknown;
	isEmpty?: boolean;
	loadingText?: string;
	errorText?: string;
	emptyText?: string;
	className?: string;
	// Immuch360: what Retry does after an error; by default the page's queries run again
	onRetry?: () => void;
	children: React.ReactNode;
}

export const QueryStateView: React.FC<QueryStateViewProps> = ({
	isLoading,
	error,
	isEmpty = false,
	loadingText = t('webos_loading'),
	errorText,
	emptyText = t('nothing_here_yet'),
	className,
	onRetry,
	children,
}) => {
	const online = useOnline();
	const queryClient = useContext(QueryClientContext);
	const retry = useCallback(() => {
		if (onRetry) onRetry();
		else void queryClient?.refetchQueries({type: 'active'});
	}, [onRetry, queryClient]);

	const stateClass = className ? `${css.state} ${className}` : css.state;
	// Immuch360: offline, a page with nothing to show says so (TanStack Query pauses its requests then, and the page
	// read as empty); what it already loaded stays on screen
	if (!online && (isLoading || !!error || isEmpty)) return <div className={stateClass}>{t('webos_error_offline')}</div>;
	if (isLoading) return <div className={stateClass}>{loadingText}</div>;
	if (error) {
		return (
			<div className={`${stateClass} ${css.failed}`}>
				<span className={css.message}>{errorText ?? presentError(error)}</span>
				{(onRetry || queryClient) && (
					<Button size="small" onClick={retry} className={css.retry}>
						{t('retry')}
					</Button>
				)}
			</div>
		);
	}
	if (isEmpty) return <div className={stateClass}>{emptyText}</div>;
	return <>{children}</>;
};

QueryStateView.displayName = 'QueryStateView';
