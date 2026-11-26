"""One Katib trial for the shared tabular workload: prints `accuracy=<value>`."""
import argparse

import pandas as pd

import tabular

p = argparse.ArgumentParser()
p.add_argument("--n_estimators", type=int)
p.add_argument("--max_depth", type=int)
a = p.parse_args()
train_df, test_df = tabular.split(pd.concat([tabular.gen_batch(1), tabular.gen_batch(2)], ignore_index=True))
scores = tabular.evaluate(tabular.train(train_df, n_estimators=a.n_estimators, max_depth=a.max_depth), test_df)
print(f"accuracy={scores['accuracy']:.4f}")
print(f"roc_auc={scores['roc_auc']:.4f}")
