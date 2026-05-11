defmodule PhoenixKitDocumentCreator.GettextTest do
  use ExUnit.Case, async: true

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates `PhoenixKit.Dashboard.Tab.localized_label/1`.
  # Once the consumer upgrades, the helper detects it and these tests
  # run automatically.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab

  test "PhoenixKitDocumentCreator.Gettext compiles and is a valid gettext backend" do
    assert Code.ensure_loaded?(PhoenixKitDocumentCreator.Gettext)
  end

  test "Tab.localized_label/1 returns Russian translation for Document Creator" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    tab = %Tab{
      id: :admin_document_creator,
      label: "Document Creator",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Создание документов"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 returns Estonian translation for Document Creator" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "et")

    tab = %Tab{
      id: :admin_document_creator,
      label: "Document Creator",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Dokumentide loomine"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 translates child tab labels (Documents/Templates) in ru" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    docs = %Tab{
      id: :admin_document_creator_documents,
      label: "Documents",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    templates = %Tab{
      id: :admin_document_creator_templates,
      label: "Templates",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(docs) == "Документы"
    assert Tab.localized_label(templates) == "Шаблоны"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 translates child tab labels (Documents/Templates) in et" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "et")

    docs = %Tab{
      id: :admin_document_creator_documents,
      label: "Documents",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    templates = %Tab{
      id: :admin_document_creator_templates,
      label: "Templates",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(docs) == "Dokumendid"
    assert Tab.localized_label(templates) == "Mallid"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end

  test "Tab.localized_label/1 falls back to raw label when no gettext_backend set" do
    tab = %Tab{id: :admin_document_creator, label: "Document Creator"}
    assert Tab.localized_label(tab) == "Document Creator"
  end

  test "Tab.localized_label/1 falls back to msgid when translation is missing" do
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "ru")

    tab = %Tab{
      id: :admin_unknown,
      label: "This string has no translation",
      gettext_backend: PhoenixKitDocumentCreator.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "This string has no translation"
  after
    Gettext.put_locale(PhoenixKitDocumentCreator.Gettext, "en")
  end
end
