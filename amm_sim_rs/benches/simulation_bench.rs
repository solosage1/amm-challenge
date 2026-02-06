//! Benchmarks for the simulation engine.

use criterion::{black_box, criterion_group, criterion_main, Criterion};

// Note: Full benchmarks require compiled Solidity bytecode.
// These benchmarks test the non-EVM components.

fn benchmark_wad_operations(c: &mut Criterion) {
    use amm_sim_rs::types::wad::Wad;

    let a = Wad::from_f64(1000.5);
    let b = Wad::from_f64(0.0025);

    c.bench_function("wad_wmul", |bench| {
        bench.iter(|| black_box(a).wmul(black_box(b)))
    });

    c.bench_function("wad_wdiv", |bench| {
        bench.iter(|| black_box(a).wdiv(black_box(b)))
    });

    c.bench_function("wad_sqrt", |bench| {
        bench.iter(|| black_box(a).sqrt())
    });
}

fn benchmark_price_process(c: &mut Criterion) {
    use amm_sim_rs::market::GBMPriceProcess;

    let mut process = GBMPriceProcess::new(100.0, 0.0, 0.001, 1.0, Some(42));

    c.bench_function("gbm_step", |bench| {
        bench.iter(|| process.step())
    });
}

fn benchmark_trade_info_encoding(c: &mut Criterion) {
    use amm_sim_rs::types::trade_info::TradeInfo;
    use amm_sim_rs::types::wad::Wad;

    let trade = TradeInfo::new(
        true,
        Wad::from_f64(1.5),
        Wad::from_f64(1.5),
        100,
        Wad::from_f64(1001.5),
        Wad::from_f64(998.5),
    );

    let mut buffer = [0u8; 196];

    c.bench_function("trade_info_encode", |bench| {
        bench.iter(|| {
            trade.encode_calldata(&mut buffer);
            black_box(&buffer)
        })
    });
}

fn benchmark_retail_trader(c: &mut Criterion) {
    use amm_sim_rs::market::RetailTrader;

    let mut trader = RetailTrader::new(5.0, 2.0, 0.5, Some(42));

    c.bench_function("retail_generate_orders", |bench| {
        bench.iter(|| black_box(trader.generate_orders()))
    });
}

criterion_group!(
    benches,
    benchmark_wad_operations,
    benchmark_price_process,
    benchmark_trade_info_encoding,
    benchmark_retail_trader,
);

criterion_main!(benches);
