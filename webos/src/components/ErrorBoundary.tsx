import React from 'react';
import {t} from '../immuch360/i18n';

interface ErrorBoundaryProps {
	children: React.ReactNode;
	fallback?: React.ReactNode;
}

interface ErrorBoundaryState {
	hasError: boolean;
	error: Error | null;
}

export class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
	constructor(props: ErrorBoundaryProps) {
		super(props);
		this.state = {hasError: false, error: null};
	}

	static getDerivedStateFromError(error: Error): ErrorBoundaryState {
		return {hasError: true, error};
	}

	componentDidCatch(error: Error, info: React.ErrorInfo): void {
		console.error('[ErrorBoundary] Caught error:', error, info.componentStack);
	}

	render() {
		if (this.state.hasError) {
			return (
				this.props.fallback ?? (
					<div style={{padding: 40, textAlign: 'center', color: '#fff'}}>
						<h2>{t('errors.something_went_wrong')}</h2>
						<p>{this.state.error?.message}</p>
					</div>
				)
			);
		}
		return this.props.children;
	}
}
