# unroll
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.544 | 1.640 | 242.1 | 20×10, 1×9 | 21 |
| var | var | 1.530 | 1.632 | 229.7 | 20×10, 1×9 | 21 |
| prepad16 | var | 1.534 | 1.639 | 230.0 | 21×10 | 21 |
| prepad32 | var | 1.543 | 1.632 | 235.1 | 21×10 | 21 |
| prepad48 | var | 1.528 | 1.629 | 235.7 | 20×10, 1×9 | 21 |
| rev | rev | 1.540 | 1.633 | 247.1 | 17×10, 4×9 | 21 |
| revp16 | rev | 1.549 | 1.634 | 241.3 | 20×10, 1×9 | 21 |
| revp32 | rev | 1.538 | 1.622 | 238.1 | 19×10, 2×9 | 21 |
| revp48 | rev | 1.549 | 1.643 | 251.5 | 21×10 | 21 |

- base: time 1.544–1.544, wall 1.640–1.640
- var: time 1.528–1.543, wall 1.629–1.639
- rev: time 1.538–1.549, wall 1.622–1.643
- var-code min 1.528 <= base-code max 1.544: bands overlap
- rev-code 1.538–1.549 against var-code 1.528–1.543: overlap
- at 9 collections: base 1.474 (1); var 1.389 (1); prepad48 1.414 (1); rev 1.433 (4); revp16 1.443 (1); revp32 1.448 (2)
- at 10 collections: base 1.546 (20); var 1.532 (20); prepad16 1.534 (21); prepad32 1.543 (21); prepad48 1.530 (20); rev 1.550 (17); revp16 1.549 (20); revp32 1.550 (19); revp48 1.549 (21)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.866 | 1.985 | 275.7 | 20×14, 1×13 | 21 |
| var | var | 0.889 | 1.996 | 263.9 | 21×14 | 21 |
| prepad16 | var | 0.896 | 1.974 | 261.3 | 21×14 | 21 |
| prepad32 | var | 0.879 | 1.963 | 266.9 | 21×14 | 21 |
| prepad48 | var | 0.896 | 2.010 | 268.8 | 21×14 | 21 |
| rev | rev | 0.900 | 2.017 | 284.1 | 21×14 | 21 |
| revp16 | rev | 0.900 | 1.976 | 274.9 | 21×14 | 21 |
| revp32 | rev | 0.911 | 1.983 | 273.9 | 21×14 | 21 |
| revp48 | rev | 0.902 | 2.019 | 282.5 | 21×14 | 21 |

- base: time 0.866–0.866, wall 1.985–1.985
- var: time 0.879–0.896, wall 1.963–2.010
- rev: time 0.900–0.911, wall 1.976–2.019
- var-code min 0.879 > base-code max 0.866: VAR BAND ABOVE BASE BAND
- rev-code 0.900–0.911 against var-code 0.879–0.896: REV ABOVE
- at 13 collections: base 0.862 (1)
- at 14 collections: base 0.867 (20); var 0.889 (21); prepad16 0.896 (21); prepad32 0.879 (21); prepad48 0.896 (21); rev 0.900 (21); revp16 0.900 (21); revp32 0.911 (21); revp48 0.902 (21)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.671 | 1.934 | 109.4 | 19×15, 2×14 | 21 |
| var | var | 0.709 | 1.965 | 105.6 | 20×15, 1×14 | 21 |
| prepad16 | var | 0.707 | 1.918 | 107.0 | 19×15, 1×14, 1×13 | 21 |
| prepad32 | var | 0.676 | 1.891 | 105.8 | 19×15, 2×14 | 21 |
| prepad48 | var | 0.711 | 1.970 | 105.2 | 19×15, 2×14 | 21 |
| rev | rev | 0.711 | 1.977 | 113.7 | 21×15 | 21 |
| revp16 | rev | 0.702 | 1.909 | 109.5 | 19×15, 1×13, 1×14 | 21 |
| revp32 | rev | 0.676 | 1.889 | 110.1 | 19×15, 2×14 | 21 |
| revp48 | rev | 0.711 | 1.978 | 116.5 | 20×15, 1×14 | 21 |

- base: time 0.671–0.671, wall 1.934–1.934
- var: time 0.676–0.711, wall 1.891–1.970
- rev: time 0.676–0.711, wall 1.889–1.978
- var-code min 0.676 > base-code max 0.671: VAR BAND ABOVE BASE BAND
- rev-code 0.676–0.711 against var-code 0.676–0.711: overlap
- at 13 collections: prepad16 0.685 (1); revp16 0.686 (1)
- at 14 collections: base 0.673 (2); var 0.706 (1); prepad16 0.708 (1); prepad32 0.675 (2); prepad48 0.710 (2); revp16 0.703 (1); revp32 0.681 (2); revp48 0.702 (1)
- at 15 collections: base 0.671 (19); var 0.710 (20); prepad16 0.707 (19); prepad32 0.676 (19); prepad48 0.712 (19); rev 0.711 (21); revp16 0.702 (19); revp32 0.676 (19); revp48 0.712 (20)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.649 | 1.910 | 110.7 | 21×13 | 21 |
| var | var | 0.693 | 1.963 | 105.4 | 15×14, 6×13 | 21 |
| prepad16 | var | 0.687 | 1.898 | 106.7 | 11×13, 10×14 | 21 |
| prepad32 | var | 0.660 | 1.879 | 108.5 | 21×13 | 21 |
| prepad48 | var | 0.696 | 1.959 | 104.7 | 12×14, 9×13 | 21 |
| rev | rev | 0.699 | 1.965 | 113.8 | 13×14, 6×13, 2×12 | 21 |
| revp16 | rev | 0.687 | 1.892 | 109.2 | 12×13, 9×14 | 21 |
| revp32 | rev | 0.664 | 1.875 | 110.5 | 19×13, 1×14, 1×12 | 21 |
| revp48 | rev | 0.700 | 1.961 | 113.9 | 19×14, 1×12, 1×13 | 21 |

- base: time 0.649–0.649, wall 1.910–1.910
- var: time 0.660–0.696, wall 1.879–1.963
- rev: time 0.664–0.700, wall 1.875–1.965
- var-code min 0.660 > base-code max 0.649: VAR BAND ABOVE BASE BAND
- rev-code 0.664–0.700 against var-code 0.660–0.696: overlap
- at 12 collections: rev 0.693 (2); revp32 0.659 (1); revp48 0.702 (1)
- at 13 collections: base 0.649 (21); var 0.692 (6); prepad16 0.687 (11); prepad32 0.660 (21); prepad48 0.695 (9); rev 0.699 (6); revp16 0.687 (12); revp32 0.664 (19); revp48 0.696 (1)
- at 14 collections: var 0.694 (15); prepad16 0.688 (10); prepad48 0.696 (12); rev 0.699 (13); revp16 0.690 (9); revp32 0.676 (1); revp48 0.700 (19)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.352 | 3.368 | 371.7 | 16×13, 5×14 | 21 |
| var | var | 1.361 | 3.341 | 351.2 | 20×13, 1×14 | 21 |
| prepad16 | var | 1.241 | 3.245 | 358.3 | 17×13, 4×14 | 21 |
| prepad32 | var | 1.257 | 3.235 | 355.5 | 21×13 | 21 |
| prepad48 | var | 1.359 | 3.345 | 351.2 | 20×13, 1×14 | 21 |
| rev | rev | 1.356 | 3.379 | 392.5 | 21×13 | 21 |
| revp16 | rev | 1.232 | 3.230 | 370.7 | 19×13, 2×14 | 21 |
| revp32 | rev | 1.247 | 3.242 | 363.4 | 19×13, 2×14 | 21 |
| revp48 | rev | 1.349 | 3.376 | 391.0 | 20×13, 1×14 | 21 |

- base: time 1.352–1.352, wall 3.368–3.368
- var: time 1.241–1.361, wall 3.235–3.345
- rev: time 1.232–1.356, wall 3.230–3.379
- var-code min 1.241 <= base-code max 1.352: bands overlap
- rev-code 1.232–1.356 against var-code 1.241–1.361: overlap
- at 13 collections: base 1.353 (16); var 1.361 (20); prepad16 1.241 (17); prepad32 1.257 (21); prepad48 1.359 (20); rev 1.356 (21); revp16 1.232 (19); revp32 1.247 (19); revp48 1.349 (20)
- at 14 collections: base 1.352 (5); var 1.370 (1); prepad16 1.246 (4); prepad48 1.362 (1); revp16 1.233 (2); revp32 1.247 (2); revp48 1.346 (1)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 2.983 | 3.011 | 0.0 | 21×3 | 21 |
| var | var | 3.041 | 3.059 | 0.0 | 21×3 | 21 |
| prepad16 | var | 2.974 | 2.998 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.958 | 2.980 | 0.0 | 21×3 | 21 |
| prepad48 | var | 2.974 | 2.994 | 0.0 | 21×3 | 21 |
| rev | rev | 2.975 | 2.993 | 0.0 | 21×3 | 21 |
| revp16 | rev | 2.968 | 2.989 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.963 | 2.983 | 0.0 | 21×3 | 21 |
| revp48 | rev | 3.037 | 3.058 | 0.0 | 21×3 | 21 |

- base: time 2.983–2.983, wall 3.011–3.011
- var: time 2.958–3.041, wall 2.980–3.059
- rev: time 2.963–3.037, wall 2.983–3.058
- var-code min 2.958 <= base-code max 2.983: bands overlap
- rev-code 2.963–3.037 against var-code 2.958–3.041: overlap
- at 3 collections: base 2.983 (21); var 3.041 (21); prepad16 2.974 (21); prepad32 2.958 (21); prepad48 2.974 (21); rev 2.975 (21); revp16 2.968 (21); revp32 2.963 (21); revp48 3.037 (21)

# freeing
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.439 | 1.526 | 116.6 | 11×9, 10×10 | 21 |
| var | var | 1.500 | 1.597 | 208.9 | 19×10, 2×9 | 21 |
| prepad16 | var | 1.477 | 1.551 | 211.6 | 19×10, 2×9 | 21 |
| prepad32 | var | 1.470 | 1.573 | 208.1 | 18×10, 3×9 | 21 |
| prepad48 | var | 1.511 | 1.579 | 204.4 | 19×10, 2×9 | 21 |
| rev | rev | 1.495 | 1.568 | 205.0 | 19×10, 2×9 | 21 |
| revp16 | rev | 1.495 | 1.575 | 200.7 | 20×10, 1×9 | 21 |
| revp32 | rev | 1.491 | 1.557 | 209.1 | 18×10, 3×9 | 21 |
| revp48 | rev | 1.497 | 1.567 | 209.7 | 21×10 | 21 |

- base: time 1.439–1.439, wall 1.526–1.526
- var: time 1.470–1.511, wall 1.551–1.597
- rev: time 1.491–1.497, wall 1.557–1.575
- var-code min 1.470 > base-code max 1.439: VAR BAND ABOVE BASE BAND
- rev-code 1.491–1.497 against var-code 1.470–1.511: overlap
- at 9 collections: base 1.376 (11); var 1.456 (2); prepad16 1.376 (2); prepad32 1.359 (3); prepad48 1.417 (2); rev 1.395 (2); revp16 1.386 (1); revp32 1.334 (3)
- at 10 collections: base 1.486 (10); var 1.500 (19); prepad16 1.482 (19); prepad32 1.477 (18); prepad48 1.513 (19); rev 1.501 (19); revp16 1.498 (20); revp32 1.495 (18); revp48 1.497 (21)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.825 | 1.860 | 251.1 | 21×14 | 21 |
| var | var | 0.858 | 1.894 | 234.6 | 21×14 | 21 |
| prepad16 | var | 0.856 | 1.868 | 237.5 | 21×14 | 21 |
| prepad32 | var | 0.826 | 1.855 | 234.9 | 21×14 | 21 |
| prepad48 | var | 0.860 | 1.892 | 236.8 | 21×14 | 21 |
| rev | rev | 0.841 | 1.849 | 242.0 | 21×14 | 21 |
| revp16 | rev | 0.844 | 1.893 | 236.9 | 18×14, 2×15, 1×13 | 21 |
| revp32 | rev | 0.816 | 1.837 | 238.9 | 21×14 | 21 |
| revp48 | rev | 0.850 | 1.856 | 236.1 | 21×14 | 21 |

- base: time 0.825–0.825, wall 1.860–1.860
- var: time 0.826–0.860, wall 1.855–1.894
- rev: time 0.816–0.850, wall 1.837–1.893
- var-code min 0.826 > base-code max 0.825: VAR BAND ABOVE BASE BAND
- rev-code 0.816–0.850 against var-code 0.826–0.860: overlap
- at 13 collections: revp16 0.899 (1)
- at 14 collections: base 0.825 (21); var 0.858 (21); prepad16 0.856 (21); prepad32 0.826 (21); prepad48 0.860 (21); rev 0.841 (21); revp16 0.845 (18); revp32 0.816 (21); revp48 0.850 (21)
- at 15 collections: revp16 0.840 (2)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.701 | 1.884 | 93.5 | 21×15 | 21 |
| var | var | 0.725 | 1.930 | 92.8 | 21×15 | 21 |
| prepad16 | var | 0.723 | 1.876 | 87.7 | 21×15 | 21 |
| prepad32 | var | 0.695 | 1.872 | 89.1 | 21×15 | 21 |
| prepad48 | var | 0.733 | 1.950 | 88.1 | 20×15, 1×13 | 21 |
| rev | rev | 0.729 | 1.884 | 90.1 | 20×15, 1×14 | 21 |
| revp16 | rev | 0.724 | 1.931 | 87.6 | 19×15, 1×16, 1×13 | 21 |
| revp32 | rev | 0.682 | 1.870 | 88.2 | 20×15, 1×13 | 21 |
| revp48 | rev | 0.730 | 1.883 | 91.5 | 20×15, 1×16 | 21 |

- base: time 0.701–0.701, wall 1.884–1.884
- var: time 0.695–0.733, wall 1.872–1.950
- rev: time 0.682–0.730, wall 1.870–1.931
- var-code min 0.695 <= base-code max 0.701: bands overlap
- rev-code 0.682–0.730 against var-code 0.695–0.733: overlap
- at 13 collections: prepad48 0.756 (1); revp16 0.706 (1); revp32 0.695 (1)
- at 14 collections: rev 0.733 (1)
- at 15 collections: base 0.701 (21); var 0.725 (21); prepad16 0.723 (21); prepad32 0.695 (21); prepad48 0.732 (20); rev 0.728 (20); revp16 0.724 (19); revp32 0.681 (20); revp48 0.730 (20)
- at 16 collections: revp16 0.728 (1); revp48 0.722 (1)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.688 | 1.869 | 92.2 | 18×14, 3×13 | 21 |
| var | var | 0.718 | 1.912 | 87.2 | 21×14 | 21 |
| prepad16 | var | 0.713 | 1.880 | 89.6 | 20×14, 1×13 | 21 |
| prepad32 | var | 0.685 | 1.859 | 89.0 | 20×14, 1×15 | 21 |
| prepad48 | var | 0.721 | 1.915 | 89.5 | 21×14 | 21 |
| rev | rev | 0.708 | 1.859 | 89.7 | 20×14, 1×13 | 21 |
| revp16 | rev | 0.717 | 1.922 | 90.7 | 19×14, 2×15 | 21 |
| revp32 | rev | 0.669 | 1.846 | 87.9 | 20×14, 1×13 | 21 |
| revp48 | rev | 0.718 | 1.878 | 88.0 | 20×14, 1×15 | 21 |

- base: time 0.688–0.688, wall 1.869–1.869
- var: time 0.685–0.721, wall 1.859–1.915
- rev: time 0.669–0.718, wall 1.846–1.922
- var-code min 0.685 <= base-code max 0.688: bands overlap
- rev-code 0.669–0.718 against var-code 0.685–0.721: overlap
- at 13 collections: base 0.688 (3); prepad16 0.722 (1); rev 0.707 (1); revp32 0.669 (1)
- at 14 collections: base 0.688 (18); var 0.718 (21); prepad16 0.712 (20); prepad32 0.685 (20); prepad48 0.721 (21); rev 0.708 (20); revp16 0.717 (19); revp32 0.669 (20); revp48 0.718 (20)
- at 15 collections: prepad32 0.683 (1); revp16 0.716 (2); revp48 0.715 (1)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.342 | 3.169 | 339.2 | 13×14, 8×13 | 21 |
| var | var | 1.378 | 3.212 | 343.0 | 21×14 | 21 |
| prepad16 | var | 1.282 | 3.118 | 345.1 | 19×14, 2×13 | 21 |
| prepad32 | var | 1.315 | 3.157 | 347.6 | 19×14, 2×13 | 21 |
| prepad48 | var | 1.380 | 3.194 | 336.7 | 19×14, 2×13 | 21 |
| rev | rev | 1.281 | 3.128 | 342.9 | 20×14, 1×13 | 21 |
| revp16 | rev | 1.378 | 3.218 | 343.0 | 21×14 | 21 |
| revp32 | rev | 1.340 | 3.177 | 340.0 | 18×14, 3×13 | 21 |
| revp48 | rev | 1.286 | 3.119 | 343.3 | 18×14, 3×13 | 21 |

- base: time 1.342–1.342, wall 3.169–3.169
- var: time 1.282–1.380, wall 3.118–3.212
- rev: time 1.281–1.378, wall 3.119–3.218
- var-code min 1.282 <= base-code max 1.342: bands overlap
- rev-code 1.281–1.378 against var-code 1.282–1.380: overlap
- at 13 collections: base 1.342 (8); prepad16 1.298 (2); prepad32 1.321 (2); prepad48 1.387 (2); rev 1.278 (1); revp32 1.337 (3); revp48 1.286 (3)
- at 14 collections: base 1.346 (13); var 1.378 (21); prepad16 1.281 (19); prepad32 1.315 (19); prepad48 1.379 (19); rev 1.281 (20); revp16 1.378 (21); revp32 1.341 (18); revp48 1.284 (18)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 2.638 | 2.657 | 0.0 | 21×3 | 21 |
| var | var | 2.633 | 2.652 | 0.0 | 21×3 | 21 |
| prepad16 | var | 2.644 | 2.663 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.730 | 2.760 | 0.0 | 21×3 | 21 |
| prepad48 | var | 2.624 | 2.648 | 0.0 | 21×3 | 21 |
| rev | rev | 2.643 | 2.662 | 0.0 | 21×3 | 21 |
| revp16 | rev | 2.630 | 2.652 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.637 | 2.661 | 0.0 | 21×3 | 21 |
| revp48 | rev | 2.644 | 2.662 | 0.0 | 21×3 | 21 |

- base: time 2.638–2.638, wall 2.657–2.657
- var: time 2.624–2.730, wall 2.648–2.760
- rev: time 2.630–2.644, wall 2.652–2.662
- var-code min 2.624 <= base-code max 2.638: bands overlap
- rev-code 2.630–2.644 against var-code 2.624–2.730: overlap
- at 3 collections: base 2.638 (21); var 2.633 (21); prepad16 2.644 (21); prepad32 2.730 (21); prepad48 2.624 (21); rev 2.643 (21); revp16 2.630 (21); revp32 2.637 (21); revp48 2.644 (21)

# counters
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.378 | 1.449 | 215.6 | 16×10, 5×9 | 21 |
| var | var | 1.403 | 1.474 | 203.8 | 20×10, 1×9 | 21 |
| prepad16 | var | 1.398 | 1.478 | 206.2 | 19×10, 2×9 | 21 |
| prepad32 | var | 1.381 | 1.463 | 202.4 | 19×10, 2×9 | 21 |
| prepad48 | var | 1.409 | 1.473 | 208.7 | 21×10 | 21 |
| rev | rev | 1.386 | 1.450 | 206.1 | 20×10, 1×9 | 21 |
| revp16 | rev | 1.391 | 1.455 | 203.9 | 19×10, 2×9 | 21 |
| revp32 | rev | 1.415 | 1.479 | 208.8 | 20×10, 1×9 | 21 |
| revp48 | rev | 1.399 | 1.467 | 206.7 | 20×10, 1×9 | 21 |

- base: time 1.378–1.378, wall 1.449–1.449
- var: time 1.381–1.409, wall 1.463–1.478
- rev: time 1.386–1.415, wall 1.450–1.479
- var-code min 1.381 > base-code max 1.378: VAR BAND ABOVE BASE BAND
- rev-code 1.386–1.415 against var-code 1.381–1.409: overlap
- at 9 collections: base 1.276 (5); var 1.280 (1); prepad16 1.304 (2); prepad32 1.268 (2); rev 1.332 (1); revp16 1.278 (2); revp32 1.289 (1); revp48 1.411 (1)
- at 10 collections: base 1.387 (16); var 1.405 (20); prepad16 1.400 (19); prepad32 1.383 (19); prepad48 1.409 (21); rev 1.386 (20); revp16 1.397 (19); revp32 1.415 (20); revp48 1.397 (20)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.838 | 1.859 | 242.1 | 21×14 | 21 |
| var | var | 0.844 | 1.876 | 232.5 | 21×14 | 21 |
| prepad16 | var | 0.847 | 1.837 | 228.5 | 21×14 | 21 |
| prepad32 | var | 0.816 | 1.821 | 239.5 | 21×14 | 21 |
| prepad48 | var | 0.858 | 1.895 | 233.0 | 21×14 | 21 |
| rev | rev | 0.831 | 1.854 | 231.3 | 21×14 | 21 |
| revp16 | rev | 0.827 | 1.831 | 235.1 | 16×14, 5×15 | 21 |
| revp32 | rev | 0.820 | 1.853 | 231.7 | 20×14, 1×15 | 21 |
| revp48 | rev | 0.834 | 1.862 | 235.9 | 21×14 | 21 |

- base: time 0.838–0.838, wall 1.859–1.859
- var: time 0.816–0.858, wall 1.821–1.895
- rev: time 0.820–0.834, wall 1.831–1.862
- var-code min 0.816 <= base-code max 0.838: bands overlap
- rev-code 0.820–0.834 against var-code 0.816–0.858: overlap
- at 14 collections: base 0.838 (21); var 0.844 (21); prepad16 0.847 (21); prepad32 0.816 (21); prepad48 0.858 (21); rev 0.831 (21); revp16 0.827 (16); revp32 0.821 (20); revp48 0.834 (21)
- at 15 collections: revp16 0.833 (5); revp32 0.814 (1)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.682 | 1.856 | 90.9 | 19×15, 1×13, 1×14 | 21 |
| var | var | 0.719 | 1.904 | 86.7 | 19×15, 1×14, 1×13 | 21 |
| prepad16 | var | 0.725 | 1.868 | 90.6 | 20×15, 1×16 | 21 |
| prepad32 | var | 0.690 | 1.846 | 90.2 | 20×15, 1×16 | 21 |
| prepad48 | var | 0.733 | 1.917 | 89.4 | 20×15, 1×16 | 21 |
| rev | rev | 0.713 | 1.887 | 88.2 | 21×15 | 21 |
| revp16 | rev | 0.708 | 1.862 | 87.5 | 21×15 | 21 |
| revp32 | rev | 0.698 | 1.893 | 91.4 | 20×15, 1×13 | 21 |
| revp48 | rev | 0.709 | 1.887 | 87.1 | 20×15, 1×16 | 21 |

- base: time 0.682–0.682, wall 1.856–1.856
- var: time 0.690–0.733, wall 1.846–1.917
- rev: time 0.698–0.713, wall 1.862–1.893
- var-code min 0.690 > base-code max 0.682: VAR BAND ABOVE BASE BAND
- rev-code 0.698–0.713 against var-code 0.690–0.733: overlap
- at 13 collections: base 0.711 (1); var 0.704 (1); revp32 0.681 (1)
- at 14 collections: base 0.681 (1); var 0.712 (1)
- at 15 collections: base 0.682 (19); var 0.720 (19); prepad16 0.724 (20); prepad32 0.690 (20); prepad48 0.732 (20); rev 0.713 (21); revp16 0.708 (21); revp32 0.698 (20); revp48 0.710 (20)
- at 16 collections: prepad16 0.733 (1); prepad32 0.694 (1); prepad48 0.733 (1); revp48 0.709 (1)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.674 | 1.845 | 90.9 | 21×14 | 21 |
| var | var | 0.709 | 1.900 | 87.4 | 21×14 | 21 |
| prepad16 | var | 0.712 | 1.862 | 86.5 | 18×14, 2×12, 1×15 | 21 |
| prepad32 | var | 0.679 | 1.829 | 91.8 | 20×14, 1×12 | 21 |
| prepad48 | var | 0.725 | 1.905 | 88.1 | 21×14 | 21 |
| rev | rev | 0.703 | 1.871 | 88.4 | 21×14 | 21 |
| revp16 | rev | 0.697 | 1.843 | 86.9 | 20×14, 1×13 | 21 |
| revp32 | rev | 0.693 | 1.879 | 87.5 | 21×14 | 21 |
| revp48 | rev | 0.695 | 1.874 | 87.6 | 19×14, 2×12 | 21 |

- base: time 0.674–0.674, wall 1.845–1.845
- var: time 0.679–0.725, wall 1.829–1.905
- rev: time 0.693–0.703, wall 1.843–1.879
- var-code min 0.679 > base-code max 0.674: VAR BAND ABOVE BASE BAND
- rev-code 0.693–0.703 against var-code 0.679–0.725: overlap
- at 12 collections: prepad16 0.704 (2); prepad32 0.664 (1); revp48 0.690 (2)
- at 13 collections: revp16 0.837 (1)
- at 14 collections: base 0.674 (21); var 0.709 (21); prepad16 0.713 (18); prepad32 0.679 (20); prepad48 0.725 (21); rev 0.703 (21); revp16 0.697 (20); revp32 0.693 (21); revp48 0.695 (19)
- at 15 collections: prepad16 0.705 (1)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.336 | 3.142 | 336.8 | 12×13, 9×14 | 21 |
| var | var | 1.377 | 3.183 | 333.9 | 16×14, 5×13 | 21 |
| prepad16 | var | 1.284 | 3.077 | 334.5 | 16×14, 5×13 | 21 |
| prepad32 | var | 1.287 | 3.118 | 335.0 | 17×14, 4×13 | 21 |
| prepad48 | var | 1.369 | 3.173 | 340.4 | 19×14, 2×13 | 21 |
| rev | rev | 1.344 | 3.153 | 341.1 | 20×14, 1×13 | 21 |
| revp16 | rev | 1.282 | 3.089 | 333.4 | 20×14, 1×13 | 21 |
| revp32 | rev | 1.372 | 3.193 | 338.7 | 17×14, 4×13 | 21 |
| revp48 | rev | 1.345 | 3.175 | 340.2 | 19×14, 2×13 | 21 |

- base: time 1.336–1.336, wall 3.142–3.142
- var: time 1.284–1.377, wall 3.077–3.183
- rev: time 1.282–1.372, wall 3.089–3.193
- var-code min 1.284 <= base-code max 1.336: bands overlap
- rev-code 1.282–1.372 against var-code 1.284–1.377: overlap
- at 13 collections: base 1.336 (12); var 1.380 (5); prepad16 1.290 (5); prepad32 1.290 (4); prepad48 1.382 (2); rev 1.350 (1); revp16 1.278 (1); revp32 1.368 (4); revp48 1.380 (2)
- at 14 collections: base 1.338 (9); var 1.375 (16); prepad16 1.282 (16); prepad32 1.287 (17); prepad48 1.368 (19); rev 1.344 (20); revp16 1.284 (20); revp32 1.372 (17); revp48 1.345 (19)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 2.655 | 2.676 | 0.0 | 21×3 | 21 |
| var | var | 2.626 | 2.643 | 0.0 | 21×3 | 21 |
| prepad16 | var | 2.643 | 2.665 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.728 | 2.748 | 0.0 | 21×3 | 21 |
| prepad48 | var | 2.626 | 2.644 | 0.0 | 21×3 | 21 |
| rev | rev | 2.641 | 2.659 | 0.0 | 21×3 | 21 |
| revp16 | rev | 2.729 | 2.748 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.630 | 2.649 | 0.0 | 21×3 | 21 |
| revp48 | rev | 2.637 | 2.653 | 0.0 | 21×3 | 21 |

- base: time 2.655–2.655, wall 2.676–2.676
- var: time 2.626–2.728, wall 2.643–2.748
- rev: time 2.630–2.729, wall 2.649–2.748
- var-code min 2.626 <= base-code max 2.655: bands overlap
- rev-code 2.630–2.729 against var-code 2.626–2.728: overlap
- at 3 collections: base 2.655 (21); var 2.626 (21); prepad16 2.643 (21); prepad32 2.728 (21); prepad48 2.626 (21); rev 2.641 (21); revp16 2.729 (21); revp32 2.630 (21); revp48 2.637 (21)

# idle
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.016 | 1.091 | 78.1 | 20×9, 1×10 | 21 |
| var | var | 1.023 | 1.102 | 77.5 | 20×9, 1×10 | 21 |
| prepad16 | var | 1.032 | 1.099 | 78.3 | 20×9, 1×10 | 21 |
| prepad32 | var | 1.017 | 1.111 | 79.3 | 20×9, 1×10 | 21 |
| prepad48 | var | 1.025 | 1.111 | 83.3 | 20×9, 1×10 | 21 |
| rev | rev | 0.991 | 1.074 | 79.4 | 20×9, 1×10 | 21 |
| revp16 | rev | 0.996 | 1.088 | 75.8 | 20×9, 1×10 | 21 |
| revp32 | rev | 0.992 | 1.082 | 80.4 | 21×9 | 21 |
| revp48 | rev | 1.003 | 1.083 | 80.8 | 20×9, 1×10 | 21 |

- base: time 1.016–1.016, wall 1.091–1.091
- var: time 1.017–1.032, wall 1.099–1.111
- rev: time 0.991–1.003, wall 1.074–1.088
- var-code min 1.017 > base-code max 1.016: VAR BAND ABOVE BASE BAND
- rev-code 0.991–1.003 against var-code 1.017–1.032: REV BELOW
- at 9 collections: base 1.016 (20); var 1.018 (20); prepad16 1.028 (20); prepad32 1.014 (20); prepad48 1.017 (20); rev 0.987 (20); revp16 1.004 (20); revp32 0.992 (21); revp48 0.996 (20)
- at 10 collections: base 0.949 (1); var 1.310 (1); prepad16 1.131 (1); prepad32 1.087 (1); prepad48 1.151 (1); rev 1.286 (1); revp16 0.996 (1); revp48 1.162 (1)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.551 | 1.215 | 172.7 | 21×14 | 21 |
| var | var | 0.552 | 1.228 | 168.1 | 20×14, 1×15 | 21 |
| prepad16 | var | 0.547 | 1.242 | 164.4 | 20×14, 1×15 | 21 |
| prepad32 | var | 0.556 | 1.243 | 168.6 | 20×14, 1×13 | 21 |
| prepad48 | var | 0.553 | 1.300 | 167.7 | 21×14 | 21 |
| rev | rev | 0.563 | 1.236 | 167.7 | 19×14, 1×15, 1×13 | 21 |
| revp16 | rev | 0.557 | 1.248 | 172.8 | 20×14, 1×15 | 21 |
| revp32 | rev | 0.561 | 1.233 | 167.4 | 19×14, 1×13, 1×15 | 21 |
| revp48 | rev | 0.568 | 1.246 | 173.4 | 21×14 | 21 |

- base: time 0.551–0.551, wall 1.215–1.215
- var: time 0.547–0.556, wall 1.228–1.300
- rev: time 0.557–0.568, wall 1.233–1.248
- var-code min 0.547 <= base-code max 0.551: bands overlap
- rev-code 0.557–0.568 against var-code 0.547–0.556: REV ABOVE
- at 13 collections: prepad32 0.545 (1); rev 0.562 (1); revp32 0.563 (1)
- at 14 collections: base 0.551 (21); var 0.551 (20); prepad16 0.548 (20); prepad32 0.557 (20); prepad48 0.553 (21); rev 0.563 (19); revp16 0.558 (20); revp32 0.561 (19); revp48 0.568 (21)
- at 15 collections: var 0.559 (1); prepad16 0.540 (1); rev 0.640 (1); revp16 0.541 (1); revp32 0.542 (1)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.381 | 1.145 | 66.4 | 20×14, 1×13 | 21 |
| var | var | 0.394 | 1.171 | 67.7 | 16×14, 4×13, 1×15 | 21 |
| prepad16 | var | 0.389 | 1.138 | 65.1 | 11×14, 10×13 | 21 |
| prepad32 | var | 0.387 | 1.147 | 67.4 | 19×14, 1×13, 1×15 | 21 |
| prepad48 | var | 0.393 | 1.177 | 66.7 | 12×14, 8×13, 1×15 | 21 |
| rev | rev | 0.398 | 1.165 | 66.0 | 17×14, 4×13 | 21 |
| revp16 | rev | 0.389 | 1.146 | 65.0 | 11×14, 8×13, 1×16, 1×15 | 21 |
| revp32 | rev | 0.382 | 1.143 | 67.0 | 16×14, 5×13 | 21 |
| revp48 | rev | 0.390 | 1.156 | 65.9 | 13×14, 7×13, 1×15 | 21 |

- base: time 0.381–0.381, wall 1.145–1.145
- var: time 0.387–0.394, wall 1.138–1.177
- rev: time 0.382–0.398, wall 1.143–1.165
- var-code min 0.387 > base-code max 0.381: VAR BAND ABOVE BASE BAND
- rev-code 0.382–0.398 against var-code 0.387–0.394: overlap
- at 13 collections: base 0.379 (1); var 0.390 (4); prepad16 0.389 (10); prepad32 0.382 (1); prepad48 0.386 (8); rev 0.393 (4); revp16 0.382 (8); revp32 0.383 (5); revp48 0.388 (7)
- at 14 collections: base 0.381 (20); var 0.396 (16); prepad16 0.391 (11); prepad32 0.388 (19); prepad48 0.399 (12); rev 0.402 (17); revp16 0.391 (11); revp32 0.382 (16); revp48 0.394 (13)
- at 15 collections: var 0.395 (1); prepad32 0.380 (1); prepad48 0.415 (1); revp16 0.419 (1); revp48 0.453 (1)
- at 16 collections: revp16 0.436 (1)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.378 | 1.128 | 65.2 | 21×13 | 21 |
| var | var | 0.392 | 1.154 | 65.5 | 20×13, 1×12 | 21 |
| prepad16 | var | 0.382 | 1.160 | 64.7 | 20×13, 1×12 | 21 |
| prepad32 | var | 0.380 | 1.142 | 66.3 | 21×13 | 21 |
| prepad48 | var | 0.388 | 1.155 | 65.2 | 21×13 | 21 |
| rev | rev | 0.389 | 1.149 | 65.2 | 21×13 | 21 |
| revp16 | rev | 0.384 | 1.180 | 64.7 | 20×13, 1×12 | 21 |
| revp32 | rev | 0.374 | 1.132 | 66.4 | 21×13 | 21 |
| revp48 | rev | 0.386 | 1.138 | 65.8 | 21×13 | 21 |

- base: time 0.378–0.378, wall 1.128–1.128
- var: time 0.380–0.392, wall 1.142–1.160
- rev: time 0.374–0.389, wall 1.132–1.180
- var-code min 0.380 > base-code max 0.378: VAR BAND ABOVE BASE BAND
- rev-code 0.374–0.389 against var-code 0.380–0.392: overlap
- at 12 collections: var 0.388 (1); prepad16 0.420 (1); revp16 0.409 (1)
- at 13 collections: base 0.378 (21); var 0.392 (20); prepad16 0.382 (20); prepad32 0.380 (21); prepad48 0.388 (21); rev 0.389 (21); revp16 0.384 (20); revp32 0.374 (21); revp48 0.386 (21)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.746 | 2.008 | 218.1 | 20×13, 1×14 | 21 |
| var | var | 0.766 | 2.056 | 229.7 | 14×13, 7×14 | 21 |
| prepad16 | var | 0.743 | 2.071 | 222.7 | 14×13, 7×14 | 21 |
| prepad32 | var | 0.748 | 2.101 | 230.0 | 14×13, 7×14 | 21 |
| prepad48 | var | 0.767 | 2.077 | 227.2 | 14×13, 7×14 | 21 |
| rev | rev | 0.745 | 2.089 | 234.8 | 10×14, 10×13, 1×15 | 21 |
| revp16 | rev | 0.752 | 2.020 | 221.0 | 19×13, 2×14 | 21 |
| revp32 | rev | 0.740 | 2.032 | 229.2 | 16×13, 5×14 | 21 |
| revp48 | rev | 0.747 | 2.106 | 225.9 | 12×13, 9×14 | 21 |

- base: time 0.746–0.746, wall 2.008–2.008
- var: time 0.743–0.767, wall 2.056–2.101
- rev: time 0.740–0.752, wall 2.020–2.106
- var-code min 0.743 <= base-code max 0.746: bands overlap
- rev-code 0.740–0.752 against var-code 0.743–0.767: overlap
- at 13 collections: base 0.746 (20); var 0.772 (14); prepad16 0.742 (14); prepad32 0.744 (14); prepad48 0.766 (14); rev 0.744 (10); revp16 0.752 (19); revp32 0.742 (16); revp48 0.746 (12)
- at 14 collections: base 0.736 (1); var 0.756 (7); prepad16 0.743 (7); prepad32 0.758 (7); prepad48 0.771 (7); rev 0.746 (10); revp16 0.747 (2); revp32 0.732 (5); revp48 0.757 (9)
- at 15 collections: rev 0.731 (1)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 2.306 | 2.338 | 0.0 | 21×3 | 21 |
| var | var | 2.302 | 2.389 | 0.0 | 21×3 | 21 |
| prepad16 | var | 2.340 | 2.366 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.359 | 2.386 | 0.0 | 21×3 | 21 |
| prepad48 | var | 2.319 | 2.347 | 0.0 | 21×3 | 21 |
| rev | rev | 2.360 | 2.387 | 0.0 | 21×3 | 21 |
| revp16 | rev | 2.313 | 2.340 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.338 | 2.376 | 0.0 | 21×3 | 21 |
| revp48 | rev | 2.328 | 2.347 | 0.0 | 21×3 | 21 |

- base: time 2.306–2.306, wall 2.338–2.338
- var: time 2.302–2.359, wall 2.347–2.389
- rev: time 2.313–2.360, wall 2.340–2.387
- var-code min 2.302 <= base-code max 2.306: bands overlap
- rev-code 2.313–2.360 against var-code 2.302–2.359: overlap
- at 3 collections: base 2.306 (21); var 2.302 (21); prepad16 2.340 (21); prepad32 2.359 (21); prepad48 2.319 (21); rev 2.360 (21); revp16 2.313 (21); revp32 2.338 (21); revp48 2.328 (21)

# reserve
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.203 | 1.301 | 185.1 | 13×10, 8×9 | 21 |
| var | var | 1.156 | 1.230 | 186.3 | 11×10, 10×9 | 21 |
| prepad16 | var | 1.171 | 1.260 | 193.3 | 13×10, 8×9 | 21 |
| prepad32 | var | 1.199 | 1.315 | 194.1 | 17×10, 4×9 | 21 |
| prepad48 | var | 1.155 | 1.237 | 101.4 | 14×9, 7×10 | 21 |
| rev | rev | 1.169 | 1.251 | 182.0 | 12×10, 9×9 | 21 |
| revp16 | rev | 1.201 | 1.294 | 199.7 | 15×10, 6×9 | 21 |
| revp32 | rev | 1.204 | 1.282 | 195.9 | 19×10, 2×9 | 21 |
| revp48 | rev | 1.149 | 1.232 | 101.2 | 12×9, 9×10 | 21 |

- base: time 1.203–1.203, wall 1.301–1.301
- var: time 1.155–1.199, wall 1.230–1.315
- rev: time 1.149–1.204, wall 1.232–1.294
- var-code min 1.155 <= base-code max 1.203: bands overlap
- rev-code 1.149–1.204 against var-code 1.155–1.199: overlap
- at 9 collections: base 1.121 (8); var 1.107 (10); prepad16 1.126 (8); prepad32 1.106 (4); prepad48 1.103 (14); rev 1.107 (9); revp16 1.090 (6); revp32 1.127 (2); revp48 1.093 (12)
- at 10 collections: base 1.228 (13); var 1.174 (11); prepad16 1.186 (13); prepad32 1.202 (17); prepad48 1.185 (7); rev 1.191 (12); revp16 1.219 (15); revp32 1.208 (19); revp48 1.189 (9)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.661 | 1.567 | 235.0 | 17×14, 4×13 | 21 |
| var | var | 0.665 | 1.566 | 231.5 | 21×14 | 21 |
| prepad16 | var | 0.679 | 1.535 | 229.4 | 16×14, 5×13 | 21 |
| prepad32 | var | 0.670 | 1.535 | 226.4 | 20×14, 1×13 | 21 |
| prepad48 | var | 0.672 | 1.560 | 222.6 | 19×14, 2×13 | 21 |
| rev | rev | 0.673 | 1.571 | 228.8 | 21×14 | 21 |
| revp16 | rev | 0.679 | 1.589 | 229.6 | 21×14 | 21 |
| revp32 | rev | 0.686 | 1.573 | 231.8 | 19×14, 2×13 | 21 |
| revp48 | rev | 0.674 | 1.555 | 225.5 | 21×14 | 21 |

- base: time 0.661–0.661, wall 1.567–1.567
- var: time 0.665–0.679, wall 1.535–1.566
- rev: time 0.673–0.686, wall 1.555–1.589
- var-code min 0.665 > base-code max 0.661: VAR BAND ABOVE BASE BAND
- rev-code 0.673–0.686 against var-code 0.665–0.679: overlap
- at 13 collections: base 0.682 (4); prepad16 0.679 (5); prepad32 0.707 (1); prepad48 0.673 (2); revp32 0.693 (2)
- at 14 collections: base 0.660 (17); var 0.665 (21); prepad16 0.679 (16); prepad32 0.669 (20); prepad48 0.672 (19); rev 0.673 (21); revp16 0.679 (21); revp32 0.686 (19); revp48 0.674 (21)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.523 | 1.512 | 81.7 | 14×13, 6×14, 1×15 | 21 |
| var | var | 0.524 | 1.530 | 96.5 | 10×14, 7×13, 3×15, 1×12 | 21 |
| prepad16 | var | 0.535 | 1.510 | 81.9 | 13×14, 8×13 | 21 |
| prepad32 | var | 0.530 | 1.573 | 80.7 | 11×14, 9×13, 1×15 | 21 |
| prepad48 | var | 0.534 | 1.545 | 79.9 | 10×14, 9×13, 2×15 | 21 |
| rev | rev | 0.529 | 1.592 | 97.3 | 11×14, 8×13, 2×15 | 21 |
| revp16 | rev | 0.533 | 1.586 | 97.6 | 11×14, 9×13, 1×15 | 21 |
| revp32 | rev | 0.531 | 1.516 | 80.4 | 13×13, 8×14 | 21 |
| revp48 | rev | 0.530 | 1.564 | 97.7 | 12×14, 6×13, 3×15 | 21 |

- base: time 0.523–0.523, wall 1.512–1.512
- var: time 0.524–0.535, wall 1.510–1.573
- rev: time 0.529–0.533, wall 1.516–1.592
- var-code min 0.524 > base-code max 0.523: VAR BAND ABOVE BASE BAND
- rev-code 0.529–0.533 against var-code 0.524–0.535: overlap
- at 12 collections: var 0.515 (1)
- at 13 collections: base 0.521 (14); var 0.528 (7); prepad16 0.538 (8); prepad32 0.533 (9); prepad48 0.534 (9); rev 0.528 (8); revp16 0.535 (9); revp32 0.533 (13); revp48 0.531 (6)
- at 14 collections: base 0.526 (6); var 0.524 (10); prepad16 0.534 (13); prepad32 0.530 (11); prepad48 0.532 (10); rev 0.531 (11); revp16 0.532 (11); revp32 0.528 (8); revp48 0.527 (12)
- at 15 collections: base 0.532 (1); var 0.524 (3); prepad32 0.619 (1); prepad48 0.540 (2); rev 0.623 (2); revp16 0.537 (1); revp48 0.568 (3)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.510 | 1.492 | 78.7 | 18×12, 3×13 | 21 |
| var | var | 0.509 | 1.586 | 98.5 | 14×13, 7×12 | 21 |
| prepad16 | var | 0.516 | 1.500 | 99.0 | 13×13, 8×12 | 21 |
| prepad32 | var | 0.517 | 1.538 | 80.7 | 13×12, 8×13 | 21 |
| prepad48 | var | 0.518 | 1.576 | 82.3 | 13×12, 8×13 | 21 |
| rev | rev | 0.513 | 1.568 | 97.5 | 14×13, 7×12 | 21 |
| revp16 | rev | 0.516 | 1.547 | 97.9 | 10×12, 10×13, 1×11 | 21 |
| revp32 | rev | 0.516 | 1.528 | 81.3 | 15×12, 6×13 | 21 |
| revp48 | rev | 0.513 | 1.520 | 80.1 | 13×12, 8×13 | 21 |

- base: time 0.510–0.510, wall 1.492–1.492
- var: time 0.509–0.518, wall 1.500–1.586
- rev: time 0.513–0.516, wall 1.520–1.568
- var-code min 0.509 <= base-code max 0.510: bands overlap
- rev-code 0.513–0.516 against var-code 0.509–0.518: overlap
- at 11 collections: revp16 0.505 (1)
- at 12 collections: base 0.508 (18); var 0.509 (7); prepad16 0.518 (8); prepad32 0.517 (13); prepad48 0.516 (13); rev 0.513 (7); revp16 0.517 (10); revp32 0.518 (15); revp48 0.512 (13)
- at 13 collections: base 0.514 (3); var 0.508 (14); prepad16 0.516 (13); prepad32 0.517 (8); prepad48 0.531 (8); rev 0.514 (14); revp16 0.516 (10); revp32 0.514 (6); revp48 0.532 (8)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.052 | 2.758 | 341.7 | 20×13, 1×14 | 21 |
| var | var | 1.037 | 2.773 | 333.4 | 21×13 | 21 |
| prepad16 | var | 0.959 | 2.719 | 342.2 | 20×13, 1×14 | 21 |
| prepad32 | var | 0.954 | 2.704 | 335.2 | 21×13 | 21 |
| prepad48 | var | 1.037 | 2.758 | 339.3 | 21×13 | 21 |
| rev | rev | 1.020 | 2.755 | 336.0 | 21×13 | 21 |
| revp16 | rev | 0.953 | 2.671 | 342.0 | 20×13, 1×14 | 21 |
| revp32 | rev | 0.954 | 2.685 | 337.4 | 20×13, 1×14 | 21 |
| revp48 | rev | 1.046 | 2.800 | 336.2 | 18×13, 3×14 | 21 |

- base: time 1.052–1.052, wall 2.758–2.758
- var: time 0.954–1.037, wall 2.704–2.773
- rev: time 0.953–1.046, wall 2.671–2.800
- var-code min 0.954 <= base-code max 1.052: bands overlap
- rev-code 0.953–1.046 against var-code 0.954–1.037: overlap
- at 13 collections: base 1.047 (20); var 1.037 (21); prepad16 0.958 (20); prepad32 0.954 (21); prepad48 1.037 (21); rev 1.020 (21); revp16 0.952 (20); revp32 0.953 (20); revp48 1.042 (18)
- at 14 collections: base 1.099 (1); prepad16 0.987 (1); revp16 0.967 (1); revp32 1.047 (1); revp48 1.079 (3)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 2.193 | 2.222 | 0.0 | 21×3 | 21 |
| var | var | 2.246 | 2.293 | 0.0 | 21×3 | 21 |
| prepad16 | var | 2.197 | 2.292 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.232 | 2.273 | 0.0 | 21×3 | 21 |
| prepad48 | var | 2.202 | 2.275 | 0.0 | 21×3 | 21 |
| rev | rev | 2.216 | 2.327 | 0.0 | 21×3 | 21 |
| revp16 | rev | 2.194 | 2.218 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.188 | 2.227 | 0.0 | 21×3 | 21 |
| revp48 | rev | 2.220 | 2.242 | 0.0 | 21×3 | 21 |

- base: time 2.193–2.193, wall 2.222–2.222
- var: time 2.197–2.246, wall 2.273–2.293
- rev: time 2.188–2.220, wall 2.218–2.327
- var-code min 2.197 > base-code max 2.193: VAR BAND ABOVE BASE BAND
- rev-code 2.188–2.220 against var-code 2.197–2.246: overlap
- at 3 collections: base 2.193 (21); var 2.246 (21); prepad16 2.197 (21); prepad32 2.232 (21); prepad48 2.202 (21); rev 2.216 (21); revp16 2.194 (21); revp32 2.188 (21); revp48 2.220 (21)

# staging
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.615 | 1.736 | 244.4 | 19×10, 2×9 | 21 |
| var | var | 1.600 | 1.693 | 238.8 | 20×10, 1×9 | 21 |
| prepad16 | var | 1.607 | 1.724 | 236.4 | 20×10, 1×9 | 21 |
| prepad32 | var | 1.611 | 1.760 | 235.5 | 19×10, 2×9 | 21 |
| prepad48 | var | 1.608 | 1.738 | 241.8 | 21×10 | 21 |
| rev | rev | 1.599 | 1.734 | 238.1 | 21×10 | 21 |
| revp16 | rev | 1.601 | 1.697 | 240.3 | 21×10 | 21 |
| revp32 | rev | 1.603 | 1.694 | 233.5 | 20×10, 1×9 | 21 |
| revp48 | rev | 1.623 | 1.766 | 238.7 | 21×10 | 21 |

- base: time 1.615–1.615, wall 1.736–1.736
- var: time 1.600–1.611, wall 1.693–1.760
- rev: time 1.599–1.623, wall 1.694–1.766
- var-code min 1.600 <= base-code max 1.615: bands overlap
- rev-code 1.599–1.623 against var-code 1.600–1.611: overlap
- at 9 collections: base 1.526 (2); var 1.669 (1); prepad16 1.601 (1); prepad32 1.456 (2); revp32 1.663 (1)
- at 10 collections: base 1.625 (19); var 1.590 (20); prepad16 1.618 (20); prepad32 1.637 (19); prepad48 1.608 (21); rev 1.599 (21); revp16 1.601 (21); revp32 1.602 (20); revp48 1.623 (21)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.875 | 2.004 | 279.6 | 19×14, 2×13 | 21 |
| var | var | 0.903 | 2.021 | 270.1 | 20×14, 1×13 | 21 |
| prepad16 | var | 0.906 | 1.988 | 267.4 | 21×14 | 21 |
| prepad32 | var | 0.896 | 1.982 | 278.7 | 21×14 | 21 |
| prepad48 | var | 0.904 | 2.035 | 274.7 | 21×14 | 21 |
| rev | rev | 0.901 | 2.029 | 273.9 | 21×14 | 21 |
| revp16 | rev | 0.904 | 1.995 | 271.4 | 20×14, 1×13 | 21 |
| revp32 | rev | 0.891 | 1.997 | 275.3 | 21×14 | 21 |
| revp48 | rev | 0.899 | 2.028 | 268.9 | 21×14 | 21 |

- base: time 0.875–0.875, wall 2.004–2.004
- var: time 0.896–0.906, wall 1.982–2.035
- rev: time 0.891–0.904, wall 1.995–2.029
- var-code min 0.896 > base-code max 0.875: VAR BAND ABOVE BASE BAND
- rev-code 0.891–0.904 against var-code 0.896–0.906: overlap
- at 13 collections: base 0.901 (2); var 1.053 (1); revp16 0.971 (1)
- at 14 collections: base 0.875 (19); var 0.903 (20); prepad16 0.906 (21); prepad32 0.896 (21); prepad48 0.904 (21); rev 0.901 (21); revp16 0.903 (20); revp32 0.891 (21); revp48 0.899 (21)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.673 | 1.946 | 110.5 | 20×15, 1×14 | 21 |
| var | var | 0.717 | 1.990 | 105.6 | 21×15 | 21 |
| prepad16 | var | 0.713 | 1.930 | 107.5 | 21×15 | 21 |
| prepad32 | var | 0.683 | 1.906 | 109.9 | 20×15, 1×13 | 21 |
| prepad48 | var | 0.716 | 1.987 | 107.9 | 20×15, 1×13 | 21 |
| rev | rev | 0.714 | 1.985 | 108.6 | 21×15 | 21 |
| revp16 | rev | 0.712 | 1.931 | 107.8 | 19×15, 1×13, 1×14 | 21 |
| revp32 | rev | 0.686 | 1.913 | 107.7 | 20×15, 1×14 | 21 |
| revp48 | rev | 0.716 | 1.988 | 107.2 | 21×15 | 21 |

- base: time 0.673–0.673, wall 1.946–1.946
- var: time 0.683–0.717, wall 1.906–1.990
- rev: time 0.686–0.716, wall 1.913–1.988
- var-code min 0.683 > base-code max 0.673: VAR BAND ABOVE BASE BAND
- rev-code 0.686–0.716 against var-code 0.683–0.717: overlap
- at 13 collections: prepad32 0.671 (1); prepad48 0.691 (1); revp16 0.729 (1)
- at 14 collections: base 0.673 (1); revp16 0.711 (1); revp32 0.684 (1)
- at 15 collections: base 0.674 (20); var 0.717 (21); prepad16 0.713 (21); prepad32 0.683 (20); prepad48 0.716 (20); rev 0.714 (21); revp16 0.712 (19); revp32 0.686 (20); revp48 0.716 (21)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.658 | 1.931 | 110.3 | 20×13, 1×12 | 21 |
| var | var | 0.702 | 1.975 | 107.3 | 18×14, 3×13 | 21 |
| prepad16 | var | 0.695 | 1.917 | 108.6 | 17×14, 4×13 | 21 |
| prepad32 | var | 0.663 | 1.890 | 107.5 | 20×13, 1×12 | 21 |
| prepad48 | var | 0.702 | 1.970 | 106.8 | 12×14, 9×13 | 21 |
| rev | rev | 0.700 | 1.970 | 108.0 | 16×14, 5×13 | 21 |
| revp16 | rev | 0.698 | 1.927 | 107.1 | 17×14, 4×13 | 21 |
| revp32 | rev | 0.667 | 1.890 | 106.9 | 20×13, 1×12 | 21 |
| revp48 | rev | 0.703 | 1.966 | 107.1 | 17×14, 4×13 | 21 |

- base: time 0.658–0.658, wall 1.931–1.931
- var: time 0.663–0.702, wall 1.890–1.975
- rev: time 0.667–0.703, wall 1.890–1.970
- var-code min 0.663 > base-code max 0.658: VAR BAND ABOVE BASE BAND
- rev-code 0.667–0.703 against var-code 0.663–0.702: overlap
- at 12 collections: base 0.637 (1); prepad32 0.673 (1); revp32 0.665 (1)
- at 13 collections: base 0.658 (20); var 0.694 (3); prepad16 0.692 (4); prepad32 0.663 (20); prepad48 0.702 (9); rev 0.697 (5); revp16 0.696 (4); revp32 0.667 (20); revp48 0.700 (4)
- at 14 collections: var 0.704 (18); prepad16 0.696 (17); prepad48 0.702 (12); rev 0.702 (16); revp16 0.698 (17); revp48 0.703 (17)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.364 | 3.390 | 376.1 | 19×13, 2×14 | 21 |
| var | var | 1.373 | 3.387 | 357.2 | 21×13 | 21 |
| prepad16 | var | 1.256 | 3.265 | 360.0 | 21×13 | 21 |
| prepad32 | var | 1.266 | 3.279 | 359.9 | 18×13, 3×14 | 21 |
| prepad48 | var | 1.368 | 3.380 | 362.5 | 16×13, 5×14 | 21 |
| rev | rev | 1.373 | 3.397 | 352.9 | 20×13, 1×14 | 21 |
| revp16 | rev | 1.252 | 3.268 | 359.7 | 18×13, 3×14 | 21 |
| revp32 | rev | 1.269 | 3.271 | 364.0 | 20×13, 1×14 | 21 |
| revp48 | rev | 1.367 | 3.380 | 359.0 | 17×13, 4×14 | 21 |

- base: time 1.364–1.364, wall 3.390–3.390
- var: time 1.256–1.373, wall 3.265–3.387
- rev: time 1.252–1.373, wall 3.268–3.397
- var-code min 1.256 <= base-code max 1.364: bands overlap
- rev-code 1.252–1.373 against var-code 1.256–1.373: overlap
- at 13 collections: base 1.364 (19); var 1.373 (21); prepad16 1.256 (21); prepad32 1.267 (18); prepad48 1.368 (16); rev 1.373 (20); revp16 1.252 (18); revp32 1.268 (20); revp48 1.370 (17)
- at 14 collections: base 1.363 (2); prepad32 1.265 (3); prepad48 1.368 (5); rev 1.366 (1); revp16 1.253 (3); revp32 1.269 (1); revp48 1.365 (4)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 3.013 | 3.034 | 0.0 | 21×3 | 21 |
| var | var | 3.071 | 3.092 | 0.0 | 21×3 | 21 |
| prepad16 | var | 3.003 | 3.023 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.987 | 3.018 | 0.0 | 21×3 | 21 |
| prepad48 | var | 3.007 | 3.029 | 0.0 | 21×3 | 21 |
| rev | rev | 3.065 | 3.086 | 0.0 | 21×3 | 21 |
| revp16 | rev | 3.000 | 3.020 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.990 | 3.011 | 0.0 | 21×3 | 21 |
| revp48 | rev | 3.002 | 3.022 | 0.0 | 21×3 | 21 |

- base: time 3.013–3.013, wall 3.034–3.034
- var: time 2.987–3.071, wall 3.018–3.092
- rev: time 2.990–3.065, wall 3.011–3.086
- var-code min 2.987 <= base-code max 3.013: bands overlap
- rev-code 2.990–3.065 against var-code 2.987–3.071: overlap
- at 3 collections: base 3.013 (21); var 3.071 (21); prepad16 3.003 (21); prepad32 2.987 (21); prepad48 3.007 (21); rev 3.065 (21); revp16 3.000 (21); revp32 2.990 (21); revp48 3.002 (21)

# layout
## Primes
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.218 | 1.318 | 193.0 | 17×10, 4×9 | 21 |
| var | var | 1.208 | 1.284 | 191.0 | 13×10, 8×9 | 21 |
| prepad16 | var | 1.206 | 1.322 | 194.1 | 16×10, 5×9 | 21 |
| prepad32 | var | 1.215 | 1.311 | 194.5 | 14×10, 7×9 | 21 |
| prepad48 | var | 1.197 | 1.277 | 184.6 | 11×10, 10×9 | 21 |
| baseprepad16 | base | 1.216 | 1.312 | 197.9 | 16×10, 5×9 | 21 |
| baseprepad32 | base | 1.210 | 1.310 | 119.6 | 11×9, 10×10 | 21 |
| baseprepad48 | base | 1.214 | 1.326 | 190.7 | 17×10, 4×9 | 21 |
| rev | rev | 1.227 | 1.324 | 196.2 | 14×10, 7×9 | 21 |
| revp16 | rev | 1.214 | 1.296 | 191.4 | 17×10, 4×9 | 21 |
| revp32 | rev | 1.219 | 1.315 | 196.6 | 17×10, 4×9 | 21 |
| revp48 | rev | 1.226 | 1.305 | 197.6 | 17×10, 4×9 | 21 |

- base: time 1.210–1.218, wall 1.310–1.326
- var: time 1.197–1.215, wall 1.277–1.322
- rev: time 1.214–1.227, wall 1.296–1.324
- var-code min 1.197 <= base-code max 1.218: bands overlap
- rev-code 1.214–1.227 against var-code 1.197–1.215: overlap
- at 9 collections: base 1.180 (4); var 1.151 (8); prepad16 1.125 (5); prepad32 1.170 (7); prepad48 1.171 (10); baseprepad16 1.208 (5); baseprepad32 1.136 (11); baseprepad48 1.169 (4); rev 1.137 (7); revp16 1.204 (4); revp32 1.155 (4); revp48 1.200 (4)
- at 10 collections: base 1.219 (17); var 1.220 (13); prepad16 1.228 (16); prepad32 1.216 (14); prepad48 1.197 (11); baseprepad16 1.219 (16); baseprepad32 1.248 (10); baseprepad48 1.218 (17); rev 1.256 (14); revp16 1.214 (17); revp32 1.242 (17); revp48 1.235 (17)

## JsonParsePure
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.664 | 1.577 | 235.4 | 17×14, 4×13 | 21 |
| var | var | 0.676 | 1.638 | 232.2 | 21×14 | 21 |
| prepad16 | var | 0.691 | 1.618 | 231.8 | 18×14, 3×13 | 21 |
| prepad32 | var | 0.698 | 1.611 | 231.6 | 17×14, 4×13 | 21 |
| prepad48 | var | 0.679 | 1.630 | 229.5 | 17×14, 4×13 | 21 |
| baseprepad16 | base | 0.690 | 1.615 | 239.3 | 13×13, 8×14 | 21 |
| baseprepad32 | base | 0.702 | 1.590 | 231.8 | 13×14, 8×13 | 21 |
| baseprepad48 | base | 0.670 | 1.556 | 233.7 | 15×14, 6×13 | 21 |
| rev | rev | 0.699 | 1.613 | 232.9 | 17×13, 4×14 | 21 |
| revp16 | rev | 0.672 | 1.621 | 232.3 | 12×14, 9×13 | 21 |
| revp32 | rev | 0.796 | 1.693 | 235.9 | 18×14, 3×13 | 21 |
| revp48 | rev | 0.696 | 1.628 | 232.3 | 13×13, 8×14 | 21 |

- base: time 0.664–0.702, wall 1.556–1.615
- var: time 0.676–0.698, wall 1.611–1.638
- rev: time 0.672–0.796, wall 1.613–1.693
- var-code min 0.676 <= base-code max 0.702: bands overlap
- rev-code 0.672–0.796 against var-code 0.676–0.698: overlap
- at 13 collections: base 0.665 (4); prepad16 0.688 (3); prepad32 0.690 (4); prepad48 0.724 (4); baseprepad16 0.697 (13); baseprepad32 0.690 (8); baseprepad48 0.661 (6); rev 0.697 (17); revp16 0.690 (9); revp32 0.793 (3); revp48 0.696 (13)
- at 14 collections: base 0.664 (17); var 0.676 (21); prepad16 0.702 (18); prepad32 0.702 (17); prepad48 0.678 (17); baseprepad16 0.685 (8); baseprepad32 0.706 (13); baseprepad48 0.671 (15); rev 0.752 (4); revp16 0.666 (12); revp32 0.800 (18); revp48 0.713 (8)

## JsonParseSerializable
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.527 | 1.550 | 79.4 | 17×13, 3×14, 1×12 | 21 |
| var | var | 0.534 | 1.580 | 96.9 | 11×14, 7×13, 3×15 | 21 |
| prepad16 | var | 0.538 | 1.549 | 80.8 | 12×14, 9×13 | 21 |
| prepad32 | var | 0.532 | 1.515 | 79.9 | 12×13, 8×14, 1×15 | 21 |
| prepad48 | var | 0.535 | 1.562 | 82.9 | 12×13, 7×14, 2×15 | 21 |
| baseprepad16 | base | 0.550 | 1.539 | 85.4 | 15×13, 6×14 | 21 |
| baseprepad32 | base | 0.531 | 1.554 | 80.7 | 15×13, 5×14, 1×12 | 21 |
| baseprepad48 | base | 0.546 | 1.579 | 82.9 | 14×13, 7×14 | 21 |
| rev | rev | 0.536 | 1.530 | 86.9 | 14×13, 6×14, 1×15 | 21 |
| revp16 | rev | 0.536 | 1.571 | 81.3 | 11×13, 9×14, 1×15 | 21 |
| revp32 | rev | 0.546 | 1.583 | 83.6 | 13×14, 7×13, 1×15 | 21 |
| revp48 | rev | 0.536 | 1.571 | 85.7 | 14×13, 6×14, 1×15 | 21 |

- base: time 0.527–0.550, wall 1.539–1.579
- var: time 0.532–0.538, wall 1.515–1.580
- rev: time 0.536–0.546, wall 1.530–1.583
- var-code min 0.532 <= base-code max 0.550: bands overlap
- rev-code 0.536–0.546 against var-code 0.532–0.538: overlap
- at 12 collections: base 0.562 (1); baseprepad32 0.508 (1)
- at 13 collections: base 0.525 (17); var 0.534 (7); prepad16 0.532 (9); prepad32 0.526 (12); prepad48 0.536 (12); baseprepad16 0.550 (15); baseprepad32 0.531 (15); baseprepad48 0.542 (14); rev 0.534 (14); revp16 0.531 (11); revp32 0.543 (7); revp48 0.520 (14)
- at 14 collections: base 0.567 (3); var 0.530 (11); prepad16 0.552 (12); prepad32 0.546 (8); prepad48 0.535 (7); baseprepad16 0.549 (6); baseprepad32 0.567 (5); baseprepad48 0.549 (7); rev 0.557 (6); revp16 0.538 (9); revp32 0.546 (13); revp48 0.556 (6)
- at 15 collections: var 0.550 (3); prepad32 0.602 (1); prepad48 0.540 (2); rev 0.633 (1); revp16 0.584 (1); revp32 0.550 (1); revp48 0.536 (1)

## JsonParsePull
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 0.542 | 1.589 | 82.0 | 15×12, 6×13 | 21 |
| var | var | 0.529 | 1.554 | 79.9 | 14×12, 7×13 | 21 |
| prepad16 | var | 0.522 | 1.562 | 82.6 | 15×12, 6×13 | 21 |
| prepad32 | var | 0.515 | 1.554 | 81.8 | 14×12, 6×13, 1×11 | 21 |
| prepad48 | var | 0.525 | 1.606 | 84.2 | 11×12, 10×13 | 21 |
| baseprepad16 | base | 0.519 | 1.537 | 87.8 | 20×12, 1×11 | 21 |
| baseprepad32 | base | 0.518 | 1.590 | 82.9 | 13×12, 6×13, 2×11 | 21 |
| baseprepad48 | base | 0.521 | 1.522 | 80.1 | 18×12, 2×11, 1×13 | 21 |
| rev | rev | 0.509 | 1.542 | 85.1 | 19×12, 1×13, 1×11 | 21 |
| revp16 | rev | 0.525 | 1.596 | 79.9 | 19×12, 2×13 | 21 |
| revp32 | rev | 0.534 | 1.549 | 82.2 | 13×12, 6×13, 2×11 | 21 |
| revp48 | rev | 0.507 | 1.543 | 85.3 | 20×12, 1×13 | 21 |

- base: time 0.518–0.542, wall 1.522–1.590
- var: time 0.515–0.529, wall 1.554–1.606
- rev: time 0.507–0.534, wall 1.542–1.596
- var-code min 0.515 <= base-code max 0.542: bands overlap
- rev-code 0.507–0.534 against var-code 0.515–0.529: overlap
- at 11 collections: prepad32 0.503 (1); baseprepad16 0.576 (1); baseprepad32 0.498 (2); baseprepad48 0.535 (2); rev 0.508 (1); revp32 0.610 (2)
- at 12 collections: base 0.538 (15); var 0.528 (14); prepad16 0.517 (15); prepad32 0.516 (14); prepad48 0.518 (11); baseprepad16 0.518 (20); baseprepad32 0.518 (13); baseprepad48 0.522 (18); rev 0.509 (19); revp16 0.524 (19); revp32 0.534 (13); revp48 0.510 (20)
- at 13 collections: base 0.549 (6); var 0.557 (7); prepad16 0.560 (6); prepad32 0.518 (6); prepad48 0.530 (10); baseprepad32 0.525 (6); baseprepad48 0.506 (1); rev 0.562 (1); revp16 0.573 (2); revp32 0.538 (6); revp48 0.489 (1)

## JsonGenerate
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 1.052 | 2.773 | 340.2 | 21×13 | 21 |
| var | var | 1.053 | 2.829 | 339.0 | 21×13 | 21 |
| prepad16 | var | 0.972 | 2.686 | 342.9 | 21×13 | 21 |
| prepad32 | var | 0.994 | 2.712 | 339.6 | 21×13 | 21 |
| prepad48 | var | 1.039 | 2.776 | 340.5 | 21×13 | 21 |
| baseprepad16 | base | 0.968 | 2.744 | 360.9 | 21×13 | 21 |
| baseprepad32 | base | 1.044 | 2.789 | 343.1 | 21×13 | 21 |
| baseprepad48 | base | 1.067 | 2.817 | 345.5 | 21×13 | 21 |
| rev | rev | 0.980 | 2.731 | 359.4 | 21×13 | 21 |
| revp16 | rev | 1.026 | 2.761 | 346.3 | 21×13 | 21 |
| revp32 | rev | 0.998 | 2.745 | 346.9 | 21×13 | 21 |
| revp48 | rev | 0.985 | 2.743 | 367.0 | 21×13 | 21 |

- base: time 0.968–1.067, wall 2.744–2.817
- var: time 0.972–1.053, wall 2.686–2.829
- rev: time 0.980–1.026, wall 2.731–2.761
- var-code min 0.972 <= base-code max 1.067: bands overlap
- rev-code 0.980–1.026 against var-code 0.972–1.053: overlap
- at 13 collections: base 1.052 (21); var 1.053 (21); prepad16 0.972 (21); prepad32 0.994 (21); prepad48 1.039 (21); baseprepad16 0.968 (21); baseprepad32 1.044 (21); baseprepad48 1.067 (21); rev 0.980 (21); revp16 1.026 (21); revp32 0.998 (21); revp48 0.985 (21)

## Fannkuchredux
| arm | tree | time | wall | Σ mark ms | collections | n |
|---|---|---:|---:|---:|---|---:|
| base | base | 2.215 | 2.261 | 0.0 | 21×3 | 21 |
| var | var | 2.269 | 2.312 | 0.0 | 21×3 | 21 |
| prepad16 | var | 2.195 | 2.293 | 0.0 | 21×3 | 21 |
| prepad32 | var | 2.224 | 2.273 | 0.0 | 21×3 | 21 |
| prepad48 | var | 2.275 | 2.293 | 0.0 | 21×3 | 21 |
| baseprepad16 | base | 2.270 | 2.303 | 0.0 | 21×3 | 21 |
| baseprepad32 | base | 2.275 | 2.300 | 0.0 | 21×3 | 21 |
| baseprepad48 | base | 2.260 | 2.282 | 0.0 | 21×3 | 21 |
| rev | rev | 2.317 | 2.342 | 0.0 | 21×3 | 21 |
| revp16 | rev | 2.223 | 2.239 | 0.0 | 21×3 | 21 |
| revp32 | rev | 2.232 | 2.263 | 0.0 | 21×3 | 21 |
| revp48 | rev | 2.240 | 2.301 | 0.0 | 21×3 | 21 |

- base: time 2.215–2.275, wall 2.261–2.303
- var: time 2.195–2.275, wall 2.273–2.312
- rev: time 2.223–2.317, wall 2.239–2.342
- var-code min 2.195 <= base-code max 2.275: bands overlap
- rev-code 2.223–2.317 against var-code 2.195–2.275: overlap
- at 3 collections: base 2.215 (21); var 2.269 (21); prepad16 2.195 (21); prepad32 2.224 (21); prepad48 2.275 (21); baseprepad16 2.270 (21); baseprepad32 2.275 (21); baseprepad48 2.260 (21); rev 2.317 (21); revp16 2.223 (21); revp32 2.232 (21); revp48 2.240 (21)

