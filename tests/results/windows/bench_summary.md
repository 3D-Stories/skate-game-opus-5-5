| Run | Renderer | Window | Frames | Average | Median | p95 | p99 | 1 % low | > 16.7 ms | Missed refresh | Slowest | CPU / frame | GPU / frame | GPU load |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| gl_cold | OpenGL 3.3 | windowed 1920x1080, vsync, 60 Hz | 7203 | 60.1 fps | 16.67 ms | 16.71 ms | 16.79 ms | 57.5 fps | 630 | 0 | 20.9 ms | 16.51 ms | 2.76 ms | 26 % |
| gl_vsync | OpenGL 3.3 | windowed 1920x1080, vsync, 60 Hz | 7201 | 60.0 fps | 16.67 ms | 16.71 ms | 16.76 ms | 59.3 fps | 495 | 0 | 19.7 ms | 16.50 ms | 2.40 ms | 37 % |
| gl_vsync_r1 | OpenGL 3.3 | windowed 1920x1080, vsync, 60 Hz | 7201 | 60.1 fps | 16.67 ms | 16.75 ms | 18.27 ms | 48.1 fps | 957 | 4 | 26.8 ms | 16.52 ms | 1.05 ms | 19 % |
| gl_uncapped | OpenGL 3.3 | windowed 1920x1080, no vsync, 60 Hz | 75105 | 625.9 fps | 1.43 ms | 2.65 ms | 4.13 ms | 153.0 fps | 3 | - | 18.0 ms | 1.55 ms | 1.33 ms | 87 % |
| gl_uncapped_r1 | OpenGL 3.3 | windowed 1920x1080, no vsync, 60 Hz | 75404 | 628.3 fps | 1.40 ms | 2.60 ms | 3.99 ms | 117.5 fps | 37 | - | 150.3 ms | 1.51 ms | 0.99 ms | 71 % |
| angle_cold | ANGLE, D3D11 | windowed 1920x1080, vsync, 60 Hz | 12319 | 101.2 fps | 9.54 ms | 11.58 ms | 14.62 ms | 30.3 fps | 46 | 3 | 2018.7 ms | 9.73 ms | - | 34 % |
| angle_vsync | ANGLE, D3D11 | windowed 1920x1080, vsync, 60 Hz | 12958 | 108.0 fps | 9.03 ms | 11.25 ms | 13.88 ms | 64.6 fps | 19 | 0 | 19.6 ms | 9.12 ms | - | 39 % |
| angle_uncapped | ANGLE, D3D11 | windowed 1920x1080, no vsync, 60 Hz | 12435 | 103.6 fps | 9.31 ms | 12.34 ms | 15.93 ms | 52.1 fps | 97 | - | 33.7 ms | 9.51 ms | - | 39 % |
| angle_uncapped_ssao_off (nossao) | ANGLE, D3D11 | windowed 1920x1080, no vsync, 60 Hz | 28083 | 234.0 fps | 3.67 ms | 8.63 ms | 13.07 ms | 60.8 fps | 109 | - | 40.6 ms | 4.15 ms | - | 54 % |
| angle_uncapped_msaa_off (nomsaa) | ANGLE, D3D11 | windowed 1920x1080, no vsync, 60 Hz | 36892 | 307.4 fps | 3.13 ms | 4.88 ms | 6.58 ms | 108.1 fps | 6 | - | 19.4 ms | 3.16 ms | - | 37 % |
| gl_uncapped_ssao_off (nossao) | OpenGL 3.3 | windowed 1920x1080, no vsync, 60 Hz | 76172 | 634.7 fps | 1.42 ms | 2.58 ms | 3.62 ms | 154.2 fps | 4 | - | 41.3 ms | 1.53 ms | 1.13 ms | 81 % |
| gl_uncapped_ssao_off_r1 (nossao) | OpenGL 3.3 | windowed 1920x1080, no vsync, 60 Hz | 89176 | 743.2 fps | 1.18 ms | 2.21 ms | 3.06 ms | 185.1 fps | 2 | - | 19.4 ms | 1.31 ms | 0.92 ms | 74 % |
| gl_fullscreen | OpenGL 3.3 | fullscreen 1920x1080, vsync, 60 Hz | 7201 | 60.2 fps | 16.67 ms | 16.70 ms | 16.74 ms | 59.5 fps | 454 | 0 | 17.4 ms | 16.48 ms | 3.83 ms | 33 % |
| web_vsync | Chrome, WebGL 2 (ANGLE, D3D11) | page 1920x1080 | 16493 | 133.9 fps | 6.90 ms | 10.70 ms | 14.00 ms | 27.5 fps | 58 | - | 3265.6 ms | 7.15 ms | - | - |
| web_uncapped | Chrome, WebGL 2 (ANGLE, D3D11) | page 1920x1080 | 18553 | 154.6 fps | 6.20 ms | 9.10 ms | 10.80 ms | 80.4 fps | 5 | - | 88.8 ms | 6.20 ms | - | - |
