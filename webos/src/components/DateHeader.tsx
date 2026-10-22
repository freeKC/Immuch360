import React, {useMemo} from 'react';
import {formatBucketDate} from '../utils/FormattingService';
import css from './DateHeader.module.less';

interface DateHeaderProps {
	timeBucket: string;
	// Immuch360: a heading that is no date (a folder of a network share)
	label?: string;
}

export const DateHeader: React.FC<DateHeaderProps> = React.memo(({timeBucket, label}) => {
	const displayDate = useMemo(() => label ?? formatBucketDate(timeBucket), [timeBucket, label]);
	return (
		<div className={css.dateHeader} data-spotlight-disabled="true">
			{displayDate}
		</div>
	);
});

DateHeader.displayName = 'DateHeader';
