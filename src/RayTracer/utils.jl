# Macros are like functions that run at compile time,
#    converting some input code into some output code.

# Julia can only resize 1D arrays; for multidimensional arrays
#    we have to create a new copy and replace the old.
"Resizes the given multidimensional array if needed. Does *not* preserve the contents."
macro resize_array(arr, new_size)
    # 'esc()' prevents names from getting mangled.
    # It should be applied to all user-provided code.
    arr = esc(arr)
    new_size = esc(new_size)
    return :(
        let new_size = $new_size,
            current_arr = $arr
          # If size is provided as a Vec instead of a tuple, unpack it into a tuple.
          if new_size isa Vec
              new_size = new_size.data
          end
          # If the size of the array doesn't match what's needed, replace it.
          if size(current_arr) != new_size
              $arr = typeof(current_arr)(undef, new_size)
          end
        end
    )
end