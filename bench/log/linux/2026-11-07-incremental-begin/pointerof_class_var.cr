# pointerof on class variables, Crystal 1.21: does it run the initializer again?
module PointerofClassVar
  @@call = Atomic(Int32).new(0) # initializer is a call
  @@literal = 0                 # literal
  @@uninit = uninitialized Int32

  def self.run : Nil
    @@call.set(5)
    @@literal = 5
    @@uninit = 5
    call = pointerof(@@call).value.get
    literal = pointerof(@@literal).value
    uninit = pointerof(@@uninit).value
    puts "after storing 5: call-initialised read by name #{@@call.get}, through pointerof #{call}; " \
         "literal through pointerof #{literal}; uninitialized through pointerof #{uninit}"
  end
end

PointerofClassVar.run
