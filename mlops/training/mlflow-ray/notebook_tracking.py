# Cell 3 of the JupyterHub notebook: three small training runs logged to MLflow.
# The MLflow address is preset by JupyterHub; user name and password come from cell 2.
import mlflow
from sklearn.datasets import make_classification
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split

X, y = make_classification(n_samples=2000, n_features=8, random_state=0)
X_train, X_test, y_train, y_test = train_test_split(X, y, random_state=0)

mlflow.set_experiment("training-jupyterhub-notebook")
for depth in (1, 2, 4):
    with mlflow.start_run(run_name=f"depth-{depth}"):
        model = GradientBoostingClassifier(n_estimators=50, max_depth=depth).fit(X_train, y_train)
        accuracy = model.score(X_test, y_test)
        mlflow.log_params({"max_depth": depth, "n_estimators": 50})
        mlflow.log_metric("accuracy", accuracy)
        print(f"max_depth={depth} accuracy={accuracy:.4f}")
