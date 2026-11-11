// The invitation to rate the app of the Quest store build (lib/domain/services/rate_app.service.dart): one sentence,
// Not now and Rate. Meta offers no review API, so the app asks in its own words, the same to everyone the rule lets
// through: no question, no reward. A dialog, not a sheet: a route that keeps the focus for a remote, and that suits
// the wide panel. Not now has the focus first; Back or a tap outside is Not now too.

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Shows [RateAppDialog] and gives what the user chose: Back or a tap outside is [RateAppAnswer.notNow]
Future<RateAppAnswer> showRateAppDialog(BuildContext context) async {
  final answer = await showDialog<RateAppAnswer>(context: context, builder: (_) => const RateAppDialog());
  return answer ?? RateAppAnswer.notNow;
}

/// See the top of this file
class RateAppDialog extends StatelessWidget {
  const RateAppDialog({super.key});

  static const dialogKey = Key('rate_app_dialog');
  static const notNowKey = Key('rate_app_not_now');
  static const rateKey = Key('rate_app_rate');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: dialogKey,
      content: Text(context.t.rate_app_horizon_invite),
      actions: [
        TextButton(
          key: notNowKey,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(RateAppAnswer.notNow),
          child: Text(context.t.rate_app_not_now),
        ),
        TextButton(
          key: rateKey,
          onPressed: () => Navigator.of(context).pop(RateAppAnswer.rate),
          child: Text(context.t.rate_app_rate),
        ),
      ],
    );
  }
}
