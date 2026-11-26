# Cell 3 of the Kubeflow notebook: a two-step pipeline, written and submitted
# from the notebook. Each step runs as its own pod in your project.
from kfp import Client, dsl


@dsl.component(base_image="python:3.11-slim", packages_to_install=["scikit-learn==1.6.1"])
def train(max_depth: int) -> float:
    from sklearn.datasets import make_classification
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.model_selection import train_test_split

    X, y = make_classification(n_samples=2000, n_features=8, random_state=0)
    X_train, X_test, y_train, y_test = train_test_split(X, y, random_state=0)
    return float(GradientBoostingClassifier(n_estimators=50, max_depth=max_depth).fit(X_train, y_train).score(X_test, y_test))


@dsl.component(base_image="python:3.11-slim")
def pick_best(shallow: float, deep: float) -> str:
    best = "max_depth=1" if shallow >= deep else "max_depth=4"
    print(f"shallow={shallow:.4f} deep={deep:.4f} -> {best}")
    return best


@dsl.pipeline(name="training-hello")
def hello():
    shallow = train(max_depth=1)
    deep = train(max_depth=4)
    pick_best(shallow=shallow.output, deep=deep.output)


namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
run = Client().create_run_from_pipeline_func(
    hello, arguments={}, run_name="hello-from-notebook", experiment_name="training", namespace=namespace, enable_caching=False
)
print("run id:", run.run_id)
print("state:", run.wait_for_run_completion(timeout=900).state)
