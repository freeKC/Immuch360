// "360° video renderer" in Settings, Advanced, on the computers with the troubleshooting on (design 2.3, DP1 section
// 4.3 "Sonde et dépannage"): which renderer draws the 360° videos, Automatic by default, and what the probe measured
// last on this computer, so that a report says which GPU and which tier played. The choice "mpv shader" of the design
// is not offered: DP1 dropped renderer A.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The name of [choice] in the settings
String sphereRendererChoiceLabel(Translations t, SphereRendererChoice choice) => switch (choice) {
  SphereRendererChoice.automatic => t.desktop_video_renderer_automatic,
  SphereRendererChoice.pluginFull => t.desktop_video_renderer_plugin_full,
  SphereRendererChoice.plugin4096 => t.desktop_video_renderer_plugin_4096,
  SphereRendererChoice.plugin2880 => t.desktop_video_renderer_plugin_2880,
  SphereRendererChoice.flat => t.desktop_video_renderer_flat,
};

/// What the probe kept, in words: the tier (or flat) on the GPU ANGLE names, with the frames a second measured
String rememberedRenderingLabel(Translations t, RememberedRendering remembered) {
  final renderer = switch (remembered.tier) {
    PluginTier.full => t.desktop_video_renderer_plugin_full,
    PluginTier.w4096 => t.desktop_video_renderer_plugin_4096,
    PluginTier.w2880 => t.desktop_video_renderer_plugin_2880,
    null => t.desktop_video_renderer_flat,
  };
  final fps = remembered.framesPerSecond;
  final target = remembered.targetFramesPerSecond;
  final measured = fps == null
      ? ''
      : ' (${fps.toStringAsFixed(1)}${target == null ? '' : ' / ${target.toStringAsFixed(fps < 100 ? 0 : 1)}'} fps)';
  final hwdec = remembered.hwdec;
  return t.desktop_video_renderer_measured(
    renderer: '$renderer$measured',
    gpu: '${_gpuName(remembered.glRenderer)}${hwdec == null ? '' : ', hwdec $hwdec'}',
  );
}

// "ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)" -> "Intel(R) UHD Graphics"
String _gpuName(String glRenderer) {
  final match = RegExp(r'^ANGLE \([^,]+, (.+?)(?: \(0x[0-9A-Fa-f]+\))? Direct3D').firstMatch(glRenderer);
  return match?.group(1) ?? glRenderer;
}

class SphereRendererTile extends StatefulWidget {
  const SphereRendererTile({super.key});

  @override
  State<SphereRendererTile> createState() => _SphereRendererTileState();
}

class _SphereRendererTileState extends State<SphereRendererTile> {
  SphereRendererSettings? _settings;

  @override
  void initState() {
    super.initState();
    unawaited(
      SphereRendererStore.load().then((settings) {
        if (mounted) {
          setState(() => _settings = settings);
        }
      }),
    );
  }

  Future<void> _change() async {
    final current = _settings?.choice ?? SphereRendererChoice.automatic;
    final picked = await showDialog<SphereRendererChoice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.t.desktop_video_renderer_title),
        children: [
          RadioGroup<SphereRendererChoice>(
            groupValue: current,
            onChanged: (choice) => Navigator.of(context).pop(choice),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final choice in SphereRendererChoice.values)
                  RadioListTile<SphereRendererChoice>(
                    key: Key('desktop_video_renderer_${choice.name}'),
                    value: choice,
                    title: Text(sphereRendererChoiceLabel(context.t, choice)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == current || !mounted) {
      return;
    }
    await SphereRendererStore.saveChoice(picked);
    final settings = await SphereRendererStore.load();
    if (mounted) {
      setState(() => _settings = settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final settings = _settings;
    final remembered = settings?.remembered;
    final choice = settings?.choice ?? SphereRendererChoice.automatic;
    return ListTile(
      key: const Key('desktop_video_renderer'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: const Icon(Icons.threesixty_rounded),
      title: Text(t.desktop_video_renderer_title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        [
          sphereRendererChoiceLabel(t, choice),
          remembered == null ? t.desktop_video_renderer_not_measured : rememberedRenderingLabel(t, remembered),
          t.desktop_video_renderer_gpu_hint,
        ].join('\n'),
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => unawaited(_change()),
    );
  }
}
