# Macros are like functions that run at compile time,
#    converting some input code into some output code.
# Julia can only resize 1D arrays; for multidimensional arrays
#    we have to create a new copy and replace the old.
"Resizes the given multidimensional array if needed. Does *not* preserve the contents."
macro resize_array(arr, new_size)
    # 'esc()' prevents names from getting mangled.
    arr = esc(arr)
    new_size = esc(new_size)
    return :(
        let new_size = $new_size,
            arr = $arr
          # Unpack size vectors into size tuples.
          if new_size isa Vec
              new_size = new_size.data
          end
          if size(arr) != new_size
              $arr = typeof(arr)(undef, new_size)
          end
        end
    )
end