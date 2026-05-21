# Dialyzer warnings suppressed here are false positives on *opaque* types from
# external libraries (Gettext, MapSet, Ecto.Multi). Dialyzer flags passing these
# structs across module boundaries even though the usage is correct — there is no
# way to "fix" them in our code without breaking the public API of those libs.
# Matched by {file, warning_type} (no line) so they survive line shifts.
[
  # Gettext compile-time backend: Gettext.Plural.plural/2 on macro-generated
  # plural forms (Expo.PluralForms is opaque).
  {"lib/phoenix_kit_document_creator/gettext.ex", :call_without_opaque},

  # stale_info/2 passes a %MapSet{} (opaque) to MapSet.member?/2.
  {"lib/phoenix_kit_document_creator/documents.ex", :call_without_opaque},

  # insert_document_and_sections/6 builds an %Ecto.Multi{} (opaque internals).
  {"lib/phoenix_kit_document_creator/documents/composer.ex", :call_without_opaque}
]
