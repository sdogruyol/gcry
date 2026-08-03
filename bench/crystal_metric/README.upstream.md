# Crystal Metric

This is set of 26 benchmarks for Crystal language, in one file. Program were taken from my benchmarks: [jit-benchmarks](https://github.com/kostya/jit-benchmarks), [crystal-benchmarks-game](https://github.com/kostya/crystal-benchmarks-game), [benchmarks](https://github.com/kostya/benchmarks) and from Crystal samples. Benchmarks implemented as separated classes, this is good for test multi module compilation.

## Run

```
crystal build metric.cr --release
./metric
```

Output

```
Binarytrees: ok in 0.776s, award 1.0
Brainfuck: ok in 4.364s, award 1.0
Brainfuck2: ok in 1.536s, award 1.0
Fannkuchredux: ok in 2.313s, award 1.0
Fasta: ok in 0.958s, award 1.0
Knuckeotide: ok in 0.817s, award 1.0
Mandelbrot: ok in 0.873s, award 1.0
Matmul: ok in 0.837s, award 1.0
Nbody: ok in 0.844s, award 1.0
Pidigits: ok in 0.642s, award 1.0
RegexDna: ok in 0.690s, award 1.0
Revcomp: ok in 0.961s, award 1.0
Spectralnorm: ok in 0.784s, award 1.0
Threadring: ok in 0.862s, award 1.0
Base64Encode: ok in 0.886s, award 1.0
Base64Decode: ok in 0.888s, award 1.0
Primes: ok in 1.066s, award 1.0
JsonGenerate: ok in 0.860s, award 1.0
JsonParsePure: ok in 0.935s, award 1.0
JsonParseSerializable: ok in 0.877s, award 1.0
JsonParsePull: ok in 0.874s, award 1.0
Mandelbrot2: ok in 1.177s, award 1.0
NeuralNet: ok in 1.137s, award 1.0
Noise: ok in 0.946s, award 1.0
Sudoku: ok in 0.946s, award 1.0
TextRaytracer: ok in 1.589s, award 1.0
29.4373s, 26.00/26, 1.00
```

## Crystal releases:

Results for Ryzen 3800x

![Crystal releases](https://github.com/kostya/crystal-metric/blob/master/releases.png)
