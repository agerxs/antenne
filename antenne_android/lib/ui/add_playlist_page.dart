import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/xtream.dart';
import 'library_scope.dart';

enum _Mode { account, link, file }

class AddPlaylistPage extends StatefulWidget {
  const AddPlaylistPage({super.key});

  @override
  State<AddPlaylistPage> createState() => _AddPlaylistPageState();
}

class _AddPlaylistPageState extends State<AddPlaylistPage> {
  var _mode = _Mode.account;
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _link = TextEditingController();
  final _name = TextEditingController();
  PlatformFile? _file;
  var _working = false;
  String? _error;
  var _passwordVisible = false;

  @override
  void dispose() {
    for (final controller in [_server, _username, _password, _link, _name]) {
      controller.dispose();
    }
    super.dispose();
  }

  Uri? get _remoteLink {
    final uri = Uri.tryParse(_link.text.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty ? uri : null;
  }

  bool get _canSubmit => switch (_mode) {
        _Mode.account => xtreamServer(_server.text) != null && _username.text.trim().isNotEmpty && _password.text.isNotEmpty,
        _Mode.link => _remoteLink != null,
        _Mode.file => _file != null,
      };

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles();
    if (files.isNotEmpty) setState(() => _file = files.single);
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _error = null;
    });
    final library = LibraryScope.read(context);
    final customName = _name.text.trim();
    try {
      final playlist = switch (_mode) {
        _Mode.account => await () {
            final server = xtreamServer(_server.text)!;
            return library.addXtream(customName.isEmpty ? server.host : customName, server, _username.text.trim(), _password.text);
          }(),
        _Mode.link => await library.addRemote(customName.isEmpty ? _remoteLink!.host : customName, _remoteLink.toString()),
        _Mode.file => await library.addFile(
            customName.isEmpty ? _file!.name.replaceAll(RegExp(r'\.m3u8?$', caseSensitive: false), '') : customName,
            _file!.name,
            utf8.decode(await _file!.readAsBytes(), allowMalformed: true),
          ),
      };
      if (mounted) Navigator.of(context).pop(playlist);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final footer = switch (_mode) {
      _Mode.account => 'Les identifiants Xtream Codes de ton abonnement. Le mot de passe est chiffré sur ce téléphone.',
      _Mode.link => 'Le lien M3U fourni avec ton abonnement. Il sera rechargé quand tu actualises la playlist.',
      _Mode.file => "Un fichier .m3u ou .m3u8. Ses chaînes sont copiées dans l'app.",
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle playlist')),
      body: AbsorbPointer(
        absorbing: _working,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(value: _Mode.account, label: Text('Compte'), icon: Icon(Icons.person_outline)),
                ButtonSegment(value: _Mode.link, label: Text('Lien'), icon: Icon(Icons.link)),
                ButtonSegment(value: _Mode.file, label: Text('Fichier'), icon: Icon(Icons.description_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (value) => setState(() {
                _mode = value.single;
                _error = null;
              }),
            ),
            const SizedBox(height: 20),
            ...switch (_mode) {
              _Mode.account => [
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Serveur', hintText: 'http://serveur.com:8080', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: "Nom d'utilisateur", border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: !_passwordVisible,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Mot de passe',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _passwordVisible ? 'Masquer' : 'Afficher',
                        icon: Icon(_passwordVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              _Mode.link => [
                  TextField(
                    controller: _link,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Lien M3U', hintText: 'http://fournisseur.com/get.php?…', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              _Mode.file => [
                  OutlinedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: Text(_file?.name ?? 'Choisir un fichier…'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), alignment: Alignment.centerLeft),
                  ),
                ],
            },
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
              child: Text(footer, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nom', hintText: 'Facultatif', border: OutlineInputBorder()),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(children: [
                  Icon(Icons.error_outline, color: scheme.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: TextStyle(color: scheme.error))),
                ]),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _canSubmit && !_working ? _submit : null,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: _working
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );
  }
}
