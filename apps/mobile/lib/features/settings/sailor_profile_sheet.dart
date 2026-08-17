import 'package:flutter/material.dart';

import '../../controllers/sailor_profile_controller.dart';
import '../../domain/sailor_color.dart';
import '../map/motorcycle_icon.dart';
import '../map/sailor_symbol_picker.dart';

class SailorProfileSheet extends StatefulWidget {
  const SailorProfileSheet({
    super.key,
    required this.sailorProfile,
    required this.currentVoyageActive,
  });

  final SailorProfileController sailorProfile;
  final bool currentVoyageActive;

  static Future<void> show(
    BuildContext context,
    SailorProfileController sailorProfile, {
    bool currentVoyageActive = false,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SailorProfileSheet(
      sailorProfile: sailorProfile,
      currentVoyageActive: currentVoyageActive,
    ),
  );

  @override
  State<SailorProfileSheet> createState() => _SailorProfileSheetState();
}

class _SailorProfileSheetState extends State<SailorProfileSheet> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.sailorProfile.displayName,
  );
  late MotorcycleIconStyle _style = widget.sailorProfile.motorcycleStyle;
  late SailorSymbol _symbol = widget.sailorProfile.sailorSymbol;
  late SailorColor _color = widget.sailorProfile.sailorColor;
  String? _nameError;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 180),
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sailor profile',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            widget.currentVoyageActive
                ? 'Changes are saved for your next voyage. Your current voyage keeps the identity you joined with so the roster stays consistent.'
                : 'This identity is prefilled for your next voyage.',
            style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('profile-name-field'),
            controller: _nameController,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() => _nameError = null),
            decoration: InputDecoration(
              labelText: 'Sailor name',
              counterText: '',
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 18),
          SailorSymbolPicker(
            displayName: _nameController.text,
            selectedSymbol: _symbol,
            motorcycleStyle: _style,
            badgeColor: _color.color,
            keyPrefix: 'profile-symbol',
            bikeKeyPrefix: 'profile-bike',
            onSymbolChanged: (symbol) => setState(() => _symbol = symbol),
            onMotorcycleStyleChanged: (style) => setState(() => _style = style),
          ),
          const SizedBox(height: 18),
          const Text('Your colour', style: TextStyle(color: Color(0xFFABB5C1))),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in SailorColor.values)
                Semantics(
                  button: true,
                  selected: color == _color,
                  label: '${color.label} sailor colour',
                  child: InkWell(
                    key: Key('profile-colour-${color.name}'),
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = color),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == _color
                              ? sailorBadgeStrokeColor(color.color)
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('save-sailor-profile'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save profile'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            key: const Key('replay-onboarding'),
            onPressed: _saving ? null : _replayOnboarding,
            icon: const Icon(Icons.replay_outlined),
            label: Text(
              widget.currentVoyageActive
                  ? 'Replay guide after this voyage'
                  : 'Replay setup guide',
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter the name your group will recognise.');
      return;
    }
    setState(() => _saving = true);
    await widget.sailorProfile.save(
      displayName: name,
      motorcycleStyle: _style,
      sailorSymbol: _symbol,
      sailorColor: _color,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _replayOnboarding() async {
    await widget.sailorProfile.replayOnboarding();
    if (mounted) Navigator.of(context).pop();
  }
}
