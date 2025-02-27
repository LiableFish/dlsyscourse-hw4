"""The module.
"""
import math
from typing import List, Optional, Tuple
from needle.autograd import Tensor
from needle import ops
import needle.init as init
import numpy as np


class Parameter(Tensor):
    """A special kind of tensor that represents parameters."""


def _unpack_params(value: object) -> List[Tensor]:
    if isinstance(value, Parameter):
        return [value]
    elif isinstance(value, Module):
        return value.parameters()
    elif isinstance(value, dict):
        params = []
        for k, v in value.items():
            params += _unpack_params(v)
        return params
    elif isinstance(value, (list, tuple)):
        params = []
        for v in value:
            params += _unpack_params(v)
        return params
    else:
        return []


def _child_modules(value: object) -> List["Module"]:
    if isinstance(value, Module):
        modules = [value]
        modules.extend(_child_modules(value.__dict__))
        return modules
    if isinstance(value, dict):
        modules = []
        for k, v in value.items():
            modules += _child_modules(v)
        return modules
    elif isinstance(value, (list, tuple)):
        modules = []
        for v in value:
            modules += _child_modules(v)
        return modules
    else:
        return []


class Module:
    def __init__(self):
        self.training = True

    def parameters(self) -> List[Tensor]:
        """Return the list of parameters in the module."""
        return _unpack_params(self.__dict__)

    def _children(self) -> List["Module"]:
        return _child_modules(self.__dict__)

    def eval(self):
        self.training = False
        for m in self._children():
            m.training = False

    def train(self):
        self.training = True
        for m in self._children():
            m.training = True

    def __call__(self, *args, **kwargs):
        return self.forward(*args, **kwargs)


class Identity(Module):
    def forward(self, x):
        return x


class Linear(Module):
    def __init__(
        self, in_features, out_features, bias=True, device=None, dtype="float32"
    ):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features

        weight_init_data = init.kaiming_uniform(
            fan_in=self.in_features,
            fan_out=self.out_features,
        )

        self.weight = Parameter(
            weight_init_data,
            requires_grad=True, 
            device=device,
            dtype=dtype,
        )

        self.bias = None
        if bias:
            bias_init_data = (
                init.kaiming_uniform(fan_in=self.out_features, fan_out=1)
                .reshape((1, self.out_features))
            )
            
            self.bias = Parameter(
                bias_init_data,
                requires_grad=True, 
                device=device,
                dtype=dtype,
            )



    def forward(self, X: Tensor) -> Tensor:
        mul = X @ self.weight
        if self.bias:
            mul += self.bias.broadcast_to(mul.shape)
        
        return mul


class Flatten(Module):
    def forward(self, X: Tensor) -> Tensor:
        return X.reshape((X.shape[0], np.prod(X.shape[1:])))


class ReLU(Module):
    def forward(self, X: Tensor) -> Tensor:
        return ops.relu(X)


class Tanh(Module):
    def forward(self, X: Tensor) -> Tensor:
        return ops.tanh(X)


class Sigmoid(Module):
    def __init__(self):
        super().__init__()

    def forward(self, X: Tensor) -> Tensor:
        return (1 + ops.exp(-X)) ** (-1)


class Sequential(Module):
    def __init__(self, *modules):
        super().__init__()
        self.modules = modules

    def forward(self, X: Tensor) -> Tensor:
        res = X
        for module in self.modules:
            res = module(res)

        return res


class SoftmaxLoss(Module):
    def forward(self, logits: Tensor, y: Tensor):
        one_hot = init.one_hot(n=logits.shape[1], i=y, device=y.device)
        return (ops.logsumexp(logits, axes=(1,)) - (logits * one_hot).sum((1,))).sum() / logits.shape[0]



class BatchNorm1d(Module):
    def __init__(self, dim, eps=1e-5, momentum=0.1, device=None, dtype="float32"):
        super().__init__()
        self.dim = dim
        self.eps = eps
        self.momentum = momentum
        
        self.weight = Parameter(
            init.ones(dim),
            device=device,
            dtype=dtype,
            requires_grad=True,
        )

        self.bias = Parameter(
            init.zeros(dim),
            device=device,
            dtype=dtype,
            requires_grad=True,
        )

        self.running_mean = init.zeros(
            dim,
            device=device,
            dtype=dtype,
            requires_grad=False,
        )

        self.running_var = init.ones(
            dim,
            device=device,
            dtype=dtype,
            requires_grad=False,
        )


    def forward(self, X: Tensor) -> Tensor:
        assert self.dim == X.shape[1]
        
        if self.training:
            mean = X.sum((0,)) / X.shape[0]
            self.running_mean = (1 - self.momentum) * self.running_mean + self.momentum * mean.data

            mean = mean.reshape((1, X.shape[1])).broadcast_to(X.shape)

            var = ((X - mean) ** 2).sum((0,)) / X.shape[0]
            self.running_var = (1 - self.momentum) * self.running_var + self.momentum * var.data

            var = var.reshape((1, X.shape[1])).broadcast_to(X.shape)

        else:
            mean = self.running_mean.reshape((1, X.shape[1])).broadcast_to(X.shape)
            var = self.running_var.reshape((1, X.shape[1])).broadcast_to(X.shape)

        normalized_X = (X - mean) / (var + self.eps) ** 0.5

        weight = self.weight.reshape((1, self.dim)).broadcast_to(X.shape)
        bias = self.bias.reshape((1, self.dim)).broadcast_to(X.shape)

        return weight * normalized_X + bias


class BatchNorm2d(BatchNorm1d):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def forward(self, x: Tensor):
        # nchw -> nhcw -> nhwc
        s = x.shape
        _x = x.transpose((1, 2)).transpose((2, 3)).reshape((s[0] * s[2] * s[3], s[1]))
        y = super().forward(_x).reshape((s[0], s[2], s[3], s[1]))
        return y.transpose((2,3)).transpose((1,2))


class LayerNorm1d(Module):
    def __init__(self, dim, eps=1e-5, device=None, dtype="float32"):
        super().__init__()
        self.dim = dim
        self.eps = eps
        
        self.weight = Parameter(
            init.ones(dim),
            device=device,
            dtype=dtype,
            requires_grad=True,
        )

        self.bias = Parameter(
            init.zeros(dim),
            device=device,
            dtype=dtype,
            requires_grad=True,
        )


    def forward(self, X: Tensor) -> Tensor:
        assert self.dim == X.shape[1]

        mean = X.sum((1,)) / X.shape[1]
        mean = mean.reshape((X.shape[0], 1)).broadcast_to(X.shape)

        var = ((X - mean) ** 2).sum((1,)) / X.shape[1]
        var = var.reshape((X.shape[0], 1)).broadcast_to(X.shape)

        normalized_X = (X - mean) / (var + self.eps) ** 0.5

        weight = self.weight.reshape((1, self.dim)).broadcast_to(X.shape)
        bias = self.bias.reshape((1, self.dim)).broadcast_to(X.shape)

        return weight * normalized_X + bias


class Dropout(Module):
    def __init__(self, p = 0.5):
        super().__init__()
        self.p = p

    def forward(self, X: Tensor) -> Tensor:
        if not self.training:
           return X
        
        dropout_probs = init.randb(*X.shape, p=1-self.p, device=X.device)
        return X * dropout_probs / (1 - self.p)


class Residual(Module):
    def __init__(self, fn: Module):
        super().__init__()
        self.fn = fn

    def forward(self, X: Tensor) -> Tensor:
        return X + self.fn(X)


class Conv(Module):
    """
    Multi-channel 2D convolutional layer
    IMPORTANT: Accepts inputs in NCHW format, outputs also in NCHW format
    Only supports padding=same
    No grouped convolution or dilation
    Only supports square kernels
    """
    def __init__(self, in_channels, out_channels, kernel_size, stride=1, bias=True, device=None, dtype="float32"):
        super().__init__()
        if isinstance(kernel_size, tuple):
            kernel_size = kernel_size[0]
        if isinstance(stride, tuple):
            stride = stride[0]
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.kernel_size = kernel_size
        self.stride = stride

        self.weight = Parameter(
            init.kaiming_uniform(
                fan_in=self.in_channels * self.kernel_size ** 2,
                fan_out=self.out_channels * self.kernel_size ** 2,
                shape=(self.kernel_size, self.kernel_size, self.in_channels, self.out_channels),
            ),
            device=device,
            dtype=dtype,
            requires_grad=True,
        )


        self.bias = None
        if bias:
            factor = 1 / (self.in_channels * self.kernel_size ** 2) ** 0.5
            self.bias = Parameter(
                init.rand(
                    self.out_channels,
                    low=-factor,
                    high=factor,
                ),
                device=device,
                dtype=dtype,
                requires_grad=True,
            )
        

    def forward(self, X: Tensor) -> Tensor:
        # truly works only with H == W 
        assert X.shape[-2] == X.shape[-1]

        padding = self.kernel_size  // 2

        conv = ops.conv(
            X.transpose((1, 2)).transpose((2, 3)),
            self.weight, 
            stride=self.stride, 
            padding=padding,
        )
        if self.bias is not None:
            conv += self.bias.reshape((1, 1, 1, self.out_channels)).broadcast_to(conv.shape)

        return conv.transpose((2, 3)).transpose((1, 2))


class RNNCell(Module):
    def __init__(self, input_size, hidden_size, bias=True, nonlinearity='tanh', device=None, dtype="float32"):
        """
        Applies an RNN cell with tanh or ReLU nonlinearity.

        Parameters:
        input_size: The number of expected features in the input X
        hidden_size: The number of features in the hidden state h
        bias: If False, then the layer does not use bias weights
        nonlinearity: The non-linearity to use. Can be either 'tanh' or 'relu'.

        Variables:
        W_ih: The learnable input-hidden weights of shape (input_size, hidden_size).
        W_hh: The learnable hidden-hidden weights of shape (hidden_size, hidden_size).
        bias_ih: The learnable input-hidden bias of shape (hidden_size,).
        bias_hh: The learnable hidden-hidden bias of shape (hidden_size,).

        Weights and biases are initialized from U(-sqrt(k), sqrt(k)) where k = 1/hidden_size
        """
        super().__init__()

        k = 1 / hidden_size
        low = -math.sqrt(k)
        high = math.sqrt(k)

        self.hidden_size = hidden_size

        self.W_ih = Parameter(
            init.rand(
                input_size, hidden_size,
                low=low,
                high=high,
            ),
            device=device,
            dtype=dtype,
        )

        self.W_hh = Parameter(
            init.rand(
                hidden_size, hidden_size,
                low=low,
                high=high,
            ),
            device=device,
            dtype=dtype,
        )

        self.bias_ih = self.bias_hh = None
        if bias:
            self.bias_ih = Parameter(
                init.rand(
                    hidden_size,
                    low=low,
                    high=high,
                ),
                device=device,
                dtype=dtype,
            )

            self.bias_hh = Parameter(
                init.rand(
                    hidden_size,
                    low=low,
                    high=high,
                ),
                device=device,
                dtype=dtype,
            )

        if nonlinearity == "relu":
            self.activation = ReLU()
        elif nonlinearity == "tanh":
            self.activation = Tanh()
        else:
            raise NotImplementedError()

    def forward(self, X: Tensor, h: Optional[Tensor] = None):
        """
        Inputs:
        X of shape (bs, input_size): Tensor containing input features
        h of shape (bs, hidden_size): Tensor containing the initial hidden state
            for each element in the batch. Defaults to zero if not provided.

        Outputs:
        h' of shape (bs, hidden_size): Tensor contianing the next hidden state
            for each element in the batch.
        """

        batch_size, _ = X.shape

        if h is None:
            h = init.zeros(
                batch_size, self.hidden_size, 
                device=X.device,
                dtype=X.dtype,
            )
        
        h_out = X @ self.W_ih + h @ self.W_hh

        if self.bias_ih is not None:
            h_out += (
                self.bias_ih
                .reshape((1, self.hidden_size))
                .broadcast_to((batch_size, self.hidden_size))
            )
        if self.bias_hh is not None:
            h_out += (
                self.bias_hh
                .reshape((1, self.hidden_size))
                .broadcast_to((batch_size, self.hidden_size))
            )
        
        return self.activation(h_out)

class RNN(Module):
    def __init__(self, input_size, hidden_size, num_layers=1, bias=True, nonlinearity='tanh', device=None, dtype="float32"):
        """
        Applies a multi-layer RNN with tanh or ReLU non-linearity to an input sequence.

        Parameters:
        input_size - The number of expected features in the input x
        hidden_size - The number of features in the hidden state h
        num_layers - Number of recurrent layers.
        nonlinearity - The non-linearity to use. Can be either 'tanh' or 'relu'.
        bias - If False, then the layer does not use bias weights.

        Variables:
        rnn_cells[k].W_ih: The learnable input-hidden weights of the k-th layer,
            of shape (input_size, hidden_size) for k=0. Otherwise the shape is
            (hidden_size, hidden_size).
        rnn_cells[k].W_hh: The learnable hidden-hidden weights of the k-th layer,
            of shape (hidden_size, hidden_size).
        rnn_cells[k].bias_ih: The learnable input-hidden bias of the k-th layer,
            of shape (hidden_size,).
        rnn_cells[k].bias_hh: The learnable hidden-hidden bias of the k-th layer,
            of shape (hidden_size,).
        """
        super().__init__()
        self.hidden_size = hidden_size

        self.rnn_cells: List[RNNCell] = []
        self.rnn_cells.append(
            RNNCell(
                input_size,
                hidden_size,
                device=device,
                dtype=dtype,
                nonlinearity=nonlinearity,
                bias=bias,
            ),
        )
        for _ in range(num_layers - 1):
            self.rnn_cells.append(
                RNNCell(
                    hidden_size,
                    hidden_size,
                    device=device,
                    dtype=dtype,
                    nonlinearity=nonlinearity,
                    bias=bias,
                ),
            )

    def forward(self, X: Tensor, h0: Optional[Tensor] = None):
        """
        Inputs:
        X of shape (seq_len, bs, input_size) containing the features of the input sequence.
        h_0 of shape (num_layers, bs, hidden_size) containing the initial
            hidden state for each element in the batch. Defaults to zeros if not provided.

        Outputs
        output of shape (seq_len, bs, hidden_size) containing the output features
            (h_t) from the last layer of the RNN, for each t.
        h_n of shape (num_layers, bs, hidden_size) containing the final hidden state for each element in the batch.
        """
        _, batch_size, _ = X.shape
        num_layers = len(self.rnn_cells)
        
        if h0 is None:
            h0 = init.zeros(
                num_layers, batch_size, self.hidden_size,
                device=X.device,
                dtype=X.dtype,
            )

        X_prev = X
        hn_output = []
        for rnn_cell, h_prev in zip(self.rnn_cells, ops.split(h0, axis=0)):
            hs = []
            for X_t in ops.split(X_prev, axis=0):           
                h = rnn_cell(X_t, h_prev)
                h_prev = h
                hs.append(h)
            X_prev = ops.stack(hs, axis=0)
            hn_output.append(hs[-1])

        return X_prev, ops.stack(hn_output, axis=0)


class LSTMCell(Module):
    def __init__(self, input_size, hidden_size, bias=True, device=None, dtype="float32"):
        """
        A long short-term memory (LSTM) cell.

        Parameters:
        input_size - The number of expected features in the input X
        hidden_size - The number of features in the hidden state h
        bias - If False, then the layer does not use bias weights

        Variables:
        W_ih - The learnable input-hidden weights, of shape (input_size, 4*hidden_size).
        W_hh - The learnable hidden-hidden weights, of shape (hidden_size, 4*hidden_size).
        bias_ih - The learnable input-hidden bias, of shape (4*hidden_size,).
        bias_hh - The learnable hidden-hidden bias, of shape (4*hidden_size,).

        Weights and biases are initialized from U(-sqrt(k), sqrt(k)) where k = 1/hidden_size
        """
        super().__init__()

        k = 1 / hidden_size
        low = -math.sqrt(k)
        high = math.sqrt(k)

        self.hidden_size = hidden_size

        self.W_ih = Parameter(
            init.rand(
                input_size, 4 * hidden_size,
                low=low,
                high=high,
            ),
            device=device,
            dtype=dtype,
        )

        self.W_hh = Parameter(
            init.rand(
                hidden_size, 4 * hidden_size,
                low=low,
                high=high,
            ),
            device=device,
            dtype=dtype,
        )

        self.bias_ih = self.bias_hh = None
        if bias:
            self.bias_ih = Parameter(
                init.rand(
                    4 * hidden_size,
                    low=low,
                    high=high,
                ),
                device=device,
                dtype=dtype,
            )

            self.bias_hh = Parameter(
                init.rand(
                    4 * hidden_size,
                    low=low,
                    high=high,
                ),
                device=device,
                dtype=dtype,
            )

    def forward(self, X: Tensor, h: Optional[Tuple[Tensor]] = None):
        """
        Inputs: X, h
        X of shape (batch, input_size): Tensor containing input features
        h, tuple of (h0, c0), with
            h0 of shape (bs, hidden_size): Tensor containing the initial hidden state
                for each element in the batch. Defaults to zero if not provided.
            c0 of shape (bs, hidden_size): Tensor containing the initial cell state
                for each element in the batch. Defaults to zero if not provided.

        Outputs: (h', c')
        h' of shape (bs, hidden_size): Tensor containing the next hidden state for each
            element in the batch.
        c' of shape (bs, hidden_size): Tensor containing the next cell state for each
            element in the batch.
        """
        batch_size, _ = X.shape

        if h is None:
            h0 = init.zeros(
                batch_size, self.hidden_size, 
                device=X.device,
                dtype=X.dtype,
            )
            c0 = init.zeros(
                batch_size, self.hidden_size, 
                device=X.device,
                dtype=X.dtype,
            )
        else:
            h0, c0 = h
        
        intermediate = X @ self.W_ih + h0 @ self.W_hh

        if self.bias_ih is not None:
            intermediate += (
                self.bias_ih
                .reshape((1, 4 * self.hidden_size))
                .broadcast_to((batch_size, 4 * self.hidden_size))
            )
        if self.bias_hh is not None:
            intermediate += (
                self.bias_hh
                .reshape((1, 4 * self.hidden_size))
                .broadcast_to((batch_size, 4 * self.hidden_size))
            )
        
        i, f, g, o = ops.split(
            intermediate.reshape((batch_size, 4, self.hidden_size)),
            axis=1,
        )
        i, f, g, o = Sigmoid()(i), Sigmoid()(f), Tanh()(g), Sigmoid()(o)

        c_out = f * c0 + i * g
        h_out = o * Tanh()(c_out)
        return h_out, c_out


class LSTM(Module):
    def __init__(self, input_size, hidden_size, num_layers=1, bias=True, device=None, dtype="float32"):
        super().__init__()
        """
        Applies a multi-layer long short-term memory (LSTM) RNN to an input sequence.

        Parameters:
        input_size - The number of expected features in the input x
        hidden_size - The number of features in the hidden state h
        num_layers - Number of recurrent layers.
        bias - If False, then the layer does not use bias weights.

        Variables:
        lstm_cells[k].W_ih: The learnable input-hidden weights of the k-th layer,
            of shape (input_size, 4*hidden_size) for k=0. Otherwise the shape is
            (hidden_size, 4*hidden_size).
        lstm_cells[k].W_hh: The learnable hidden-hidden weights of the k-th layer,
            of shape (hidden_size, 4*hidden_size).
        lstm_cells[k].bias_ih: The learnable input-hidden bias of the k-th layer,
            of shape (4*hidden_size,).
        lstm_cells[k].bias_hh: The learnable hidden-hidden bias of the k-th layer,
            of shape (4*hidden_size,).
        """
        super().__init__()
        self.hidden_size = hidden_size

        self.lstm_cells: List[LSTMCell] = []
        self.lstm_cells.append(
            LSTMCell(
                input_size,
                hidden_size,
                device=device,
                dtype=dtype,
                bias=bias,
            ),
        )
        for _ in range(num_layers - 1):
            self.lstm_cells.append(
                LSTMCell(
                    hidden_size,
                    hidden_size,
                    device=device,
                    dtype=dtype,
                    bias=bias,
                ),
            )

    def forward(self, X: Tensor, h: Optional[Tuple[Tensor]] = None):
        """
        Inputs: X, h
        X of shape (seq_len, bs, input_size) containing the features of the input sequence.
        h, tuple of (h0, c0) with
            h_0 of shape (num_layers, bs, hidden_size) containing the initial
                hidden state for each element in the batch. Defaults to zeros if not provided.
            c0 of shape (num_layers, bs, hidden_size) containing the initial
                hidden cell state for each element in the batch. Defaults to zeros if not provided.

        Outputs: (output, (h_n, c_n))
        output of shape (seq_len, bs, hidden_size) containing the output features
            (h_t) from the last layer of the LSTM, for each t.
        tuple of (h_n, c_n) with
            h_n of shape (num_layers, bs, hidden_size) containing the final hidden state for each element in the batch.
            c_n of shape (num_layers, bs, hidden_size) containing the final hidden cell state for each element in the batch.
        """
        _, batch_size, _ = X.shape
        num_layers = len(self.lstm_cells)
        
        if h is None:
            h0 = init.zeros(
                num_layers, batch_size, self.hidden_size,
                device=X.device,
                dtype=X.dtype,
            )
            c0 = init.zeros(
                num_layers, batch_size, self.hidden_size,
                device=X.device,
                dtype=X.dtype,
            )
        else:
            h0, c0 = h

        X_prev = X
        hn_output = []
        cn_output = []
        for lstm_cell, h_prev, c_prev in zip(
            self.lstm_cells, ops.split(h0, axis=0), ops.split(c0, axis=0)
        ):
            hs = []
            cs = []
            for X_t in ops.split(X_prev, axis=0):           
                h, c = lstm_cell(X_t, (h_prev, c_prev))
                h_prev = h
                c_prev = c
                hs.append(h)
                cs.append(c)
            X_prev = ops.stack(hs, axis=0)
            hn_output.append(hs[-1])
            cn_output.append(cs[-1])

        return X_prev, (ops.stack(hn_output, axis=0), ops.stack(cn_output, axis=0))

class Embedding(Module):
    def __init__(self, num_embeddings: int, embedding_dim: int, device=None, dtype="float32"):
        super().__init__()
        """
        Maps one-hot word vectors from a dictionary of fixed size to embeddings.

        Parameters:
        num_embeddings (int) - Size of the dictionary
        embedding_dim (int) - The size of each embedding vector

        Variables:
        weight - The learnable weights of shape (num_embeddings, embedding_dim)
            initialized from N(0, 1).
        """
        self.num_embeddings = num_embeddings
        self.embedding_dim = embedding_dim

        self.weight = Parameter(
            init.randn(self.num_embeddings, self.embedding_dim),
            device=device,
            dtype=dtype,
        )

    def forward(self, X: Tensor) -> Tensor:
        """
        Maps word indices to one-hot vectors, and projects to embedding vectors

        Input:
        x of shape (seq_len, bs)

        Output:
        output of shape (seq_len, bs, embedding_dim)
        """
        seq_len, bs = X.shape

        one_hot = init.one_hot(
            n=self.num_embeddings,
            i=X.reshape((seq_len * bs,)),
            device=X.device,
            dtype=X.dtype,
        )

        res = one_hot @ self.weight
        return res.reshape((seq_len, bs, self.embedding_dim))
