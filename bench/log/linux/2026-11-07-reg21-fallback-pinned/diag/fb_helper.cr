# Scratch only: the public read the fix's claim_stress asks, on the tree before.
class Gcry::Heap
  def on_fallback_cursor_set? : Bool
    set = cursor_set_cached
    !set.null? && set == @fallback_cursor_set
  end
end
