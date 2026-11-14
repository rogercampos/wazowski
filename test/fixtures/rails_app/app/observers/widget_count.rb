class WidgetCount < Wazowski::Observer
  $loads << name

  observable(:count) do
    depends_on Widget, :none
    handler(Widget) { |widget, event| $events << [WidgetCount.name, event, widget.name] }
  end
end
