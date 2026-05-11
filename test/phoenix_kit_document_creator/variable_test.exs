defmodule PhoenixKitDocumentCreator.VariableTest do
  use ExUnit.Case, async: true

  describe "struct shape" do
    test "variable has a config map, defaulting to empty" do
      v = %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: :text}
      assert v.config == %{}
    end

    test "image and image_list are valid types" do
      for t <- [:image, :image_list] do
        assert %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: t}.type == t
      end
    end
  end

  describe "extract_string_variables/1" do
    test "extracts plain text variables" do
      text = "Hello {{ name }} and {{ company }}"

      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) ==
               ["company", "name"]
    end

    test "deliberately ignores {{ image: x }} tokens" do
      text = "Logo: {{ image: logo }} and name {{ name }}"
      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) == ["name"]
    end

    test "deliberately ignores {{ images: x }} tokens" do
      text = "Gallery: {{ images: photos }} and name {{ name }}"
      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) == ["name"]
    end

    test "returns [] for non-binary input" do
      assert PhoenixKitDocumentCreator.Variable.extract_string_variables(:atom) == []
    end
  end
end
