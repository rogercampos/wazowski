# Nested under a model, in a directory of its own.
class Widget
  class Audit < Wazowski::Observer
    $loads << name

    observable(:audit) do
      depends_on Widget, :name
      handler(Widget) { |widget, event| $events << [Audit.name, event, widget.name] }
    end
  end
end
