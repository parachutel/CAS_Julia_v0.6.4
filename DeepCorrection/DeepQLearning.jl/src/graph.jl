
# push!(LOAD_PATH, "./")
# push!(LOAD_PATH, "../")

using Distributions

### For building the tensorflow graph

const Q_SCOPE = "active_q"
const TARGET_Q_SCOPE = "target_q"

"""
    TrainGraph
type to store all the tensor of the DQN graph including both the Q network
and the training operations
"""
mutable struct TrainGraph
    sess::Session
    s::Tensor
    a::Tensor
    sp::Tensor
    r::Tensor
    done_mask::Tensor
    importance_weights::Tensor
    q_lo::Tensor
    q_lo_p::Tensor
    q::Tensor
    qp::Tensor
    target_q::Tensor
    loss::Tensor
    td_errors::Tensor
    train_op::Tensor
    grad_norm::Tensor
    update_op::Tensor
end


"""
Create placeholders for DQN training: s, a, sp, r, done
The shape is inferred from the environment
"""
function build_placeholders(env::AbstractEnvironment)
    obs_dim = obs_dimensions(env)
    n_outs = n_actions(env)
    s = placeholder(Float32, shape=[-1, obs_dim...])
    a = placeholder(Int32, shape=[-1])
    sp = placeholder(Float32, shape=[-1, obs_dim...])
    r = placeholder(Float32, shape=[-1])
    done_mask = placeholder(Bool, shape=[-1])
    w = placeholder(Float32, shape=[-1])
    q_lo = placeholder(Float32, shape=[-1, n_actions(env)])
    q_lo_p = placeholder(Float32, shape=[-1, n_actions(env)])
    return s, a, sp, r, done_mask, w, q_lo, q_lo_p
end



function additive_correction(solver::DeepQLearningSolver, q_lo::Q, q_corr::Q, correction_weight::Float64) where Q <:Union{Array{Float64}, Tensor}
    # q_lo is already normalized ? @ outdated comment @ 
    if solver.weighted_correction_sum == true
        return correction_weight * q_corr + (1 - correction_weight) * q_lo
    else
        return q_corr + q_lo
    end
end

"""
Build the loss operation
relies on the Bellman equation
"""
function build_loss(solver::DeepQLearningSolver,
                    env::AbstractEnvironment,
                    q_lo::Tensor,
                    q_lo_p::Tensor,
                    q::Tensor,
                    target_q::Tensor,
                    a::Tensor, 
                    r::Tensor,
                    done_mask::Tensor,
                    importance_weights::Tensor)
    if env.nn_policy == true
        env.correction_weight = 1.0
        loss, td_errors = nothing, nothing
        variable_scope("loss") do
            term = cast(done_mask, Float32)
            A = one_hot(a, n_actions(env))
            q_corr_sa = sum(A .* q, 2)
            q_sa = q_corr_sa
            q_future = target_q
            q_samp = r + (1 - term) .* discount(env.problem) .* maximum(q_future, 2)
            td_errors = q_sa - q_samp
            errors = huber_loss(td_errors)
            loss = mean(importance_weights .* errors)
        end
    else
        loss, td_errors = nothing, nothing
        variable_scope("loss") do
            term = cast(done_mask, Float32)
            A = one_hot(a, n_actions(env))
            q_corr_sa = sum(A .* q, 2)
            q_lo_sa = sum(A .* q_lo, 2)
            q_sa = additive_correction(solver, q_lo_sa, q_corr_sa, env.correction_weight)
            q_future = additive_correction(solver, q_lo_p, target_q, env.correction_weight)
            q_samp = r + (1 - term) .* discount(env.problem) .* maximum(q_future, 2)
            td_errors = q_sa - q_samp
            errors = huber_loss(td_errors)
            loss = mean(importance_weights .* errors)
        end
    end
    return loss, td_errors
end


"""
Build the loss operation with double_q
relies on the Bellman equation
"""
function build_doubleq_loss(solver::DeepQLearningSolver,
                            env::AbstractEnvironment,
                            q_lo::Tensor,
                            q_lo_p::Tensor, 
                            q::Tensor, 
                            target_q::Tensor,
                            qp::Tensor, 
                            a::Tensor, 
                            r::Tensor, 
                            done_mask::Tensor, 
                            importance_weights::Tensor)
    if env.nn_policy == true
        env.correction_weight = 1.0
        loss, td_errors = nothing, nothing
        variable_scope("loss") do
            term = cast(done_mask, Float32)
            A = one_hot(a, n_actions(env))
            q_corr_sa = sum(A .* q, 2)
            q_sa = q_corr_sa
            best_a = indmax(qp, 2)
            best_A = one_hot(best_a, n_actions(env))
            q_future = target_q
            target_q_best = sum(best_A.*q_future, 2)
            q_samp = r + (1 - term) .* discount(env.problem) .* target_q_best
            td_errors = q_sa - q_samp
            errors = huber_loss(td_errors)
            loss = mean(importance_weights.*errors)
        end
    else
        loss, td_errors = nothing, nothing
        variable_scope("loss") do
            term = cast(done_mask, Float32)
            A = one_hot(a, n_actions(env))
            q_corr_sa = sum(A .* q, 2)
            q_lo_sa = sum(A .* q_lo, 2)
            q_sa = additive_correction(solver, q_lo_sa, q_corr_sa, env.correction_weight)
            best_a = indmax(qp, 2)
            best_A = one_hot(best_a, n_actions(env))
            q_future = additive_correction(solver, q_lo_p, target_q, env.correction_weight)
            target_q_best = sum(best_A.*q_future, 2)
            q_samp = r + (1 - term) .* discount(env.problem) .* target_q_best
            td_errors = q_sa - q_samp
            errors = huber_loss(td_errors)
            loss = mean(importance_weights.*errors)
        end
    end
    return loss, td_errors
end


"""
Build train operation
Support gradient clipping
"""
function build_train_op(loss::Tensor;
                        lr::Union{Float64, Tensor} = 0.1,
                        grad_clip::Bool = true,
                        clip_val::Float64 = 10.,
                        optimizer_type=train.AdamOptimizer)

    optimizer = optimizer_type(lr)

    train_var = get_train_vars_by_name(Q_SCOPE)

    grad_vars = train.compute_gradients(optimizer, loss, train_var)
    clip_grads = grad_vars
    if grad_clip
        clip_grads = [(clip_by_norm(gradvar[1], clip_val), gradvar[2]) for gradvar in grad_vars]
    end
    train_op = train.apply_gradients(optimizer, clip_grads)
    grad_norm = global_norm([g[1] for g in clip_grads])
    return train_op, grad_norm
end

"""
returns a tensorflow operation to update a target network
if you run the operation, it will copy the value of the weights and biases in q_scope to
the weights and biases in target_q_scope
"""
function build_update_target_op(q_scope=Q_SCOPE, target_q_scope=TARGET_Q_SCOPE)
    q_weights = get_train_vars_by_name(q_scope)
    target_q_weights = get_train_vars_by_name(target_q_scope)

    all_ops = [tf.assign(target_q_weights[i], q_weights[i]) for i in 1:length(q_weights)]
    return update_target_op = tf.group(all_ops..., name="update_target_op")
end


function build_graph(solver::DeepQLearningSolver, env::AbstractEnvironment, graph=Graph())
    sess = init_session(graph)
    s, a, sp, r, done_mask, importance_weights, q_lo, q_lo_p = build_placeholders(env)

    q = build_q(s, solver.arch, env, scope=Q_SCOPE, dueling=solver.dueling) # not-normalized
    # q = tf.nn.l2_normalize(q, 2)
    qp = build_q(sp, solver.arch, env, scope=Q_SCOPE, reuse=true, dueling=solver.dueling)
    target_q = build_q(sp, solver.arch, env, scope=TARGET_Q_SCOPE, dueling=solver.dueling) # not-normalized

    if solver.double_q
        loss, td_errors = build_doubleq_loss(solver, env, q_lo, q_lo_p, q, target_q, qp, a, r, done_mask,  importance_weights)
    else
        loss, td_errors = build_loss(solver, env, q_lo, q_lo_p, q, target_q, a, r, done_mask, importance_weights)
    end

    train_op, grad_norm = build_train_op(loss, lr=solver.lr, grad_clip=solver.grad_clip, clip_val=solver.clip_val)

    update_op = build_update_target_op(Q_SCOPE, TARGET_Q_SCOPE)

    return TrainGraph(sess, s, a, sp, r, done_mask, importance_weights, q_lo, q_lo_p, 
                      q, qp, target_q, loss, td_errors, train_op, grad_norm, update_op)
end


function get_q_lo_batch(graph::TrainGraph, env::AbstractEnvironment, s_batch, sp_batch)
    bs = size(s_batch, 1)
    q_lo_batch = zeros(bs, n_actions(env))
    q_lo_p_batch = zeros(bs, n_actions(env))
    for i = 1 : bs
        q_lo_batch[i, :] = lowfi_values(env, reshape(s_batch, bs, :)[i, :])
        q_lo_p_batch[i, :] = lowfi_values(env, reshape(sp_batch, bs, :)[i, :])
    end
    return q_lo_batch, q_lo_p_batch # normalized q_lo
end
 


"""
Project specific method
"""
function get_action(graph::TrainGraph, solver::DeepQLearningSolver, env::AbstractEnvironment, o::Array{Float64})
    # If o is empty return :COC
    if all(o[[i * 3 + IND_rho for i in 0 : env.num_sections - 1]] .== 0)
        return :COC
    end

    q_low_fi = vec(lowfi_values(env, o))

    # cannot take a batch of observations
    o = reshape(o, (1, size(o)...))

    if env.nn_policy == true
        # using pure neural network policy
        q_decision = run(graph.sess, graph.q, Dict(graph.s => o) )
    else 
        # using corrected VICAS or VICAS
        if env.correction == true
            q_correction = run(graph.sess, graph.q, Dict(graph.s => o) ) # Array{Float32,2}
            # reshape q_correction
            temp_arr = zeros(n_actions(env)) # Array{Float64,1}
            for i in 1:n_actions(env)
                temp_arr[i] = q_correction[1, i]
            end
            q_correction = temp_arr # non-normalized
            # q_correction = normalize_qvals(temp_arr) # Array{Float64, 1}, normalized

            # corrected qvals for decision making
            if solver.weighted_correction_sum == true
                q_decision = env.correction_weight * q_correction + (1 - env.correction_weight) * q_low_fi
            else
                q_decision = q_correction + q_low_fi
            end

            # println("q_correction = ", q_correction)
            # println("q_low_fi = ", q_low_fi)
        else # no correction
            q_decision = q_low_fi
        end
    end

    if env.stochastic_ego_policy == false
        return actions(env)[indmax(q_decision)]
    else
        # softmax policy for ego agent
        q_decision -= maximum(q_decision)
        exp_qvals = exp.(q_decision)
        cat_dist = Categorical(exp_qvals / sum(exp_qvals))
        return actions(env)[rand(cat_dist)]
    end
end






















###### RECURRENT VERSION

"""
    RecurrentTrainGraph
type to store all the tensor of the DQN graph including both the Q network
and the training operations
"""
mutable struct RecurrentTrainGraph
    sess::Session
    s::Tensor
    a::Tensor
    sp::Tensor
    r::Tensor
    done_mask::Tensor
    trace_mask::Tensor
    importance_weights::Tensor
    q::Tensor
    hq_in::LSTMStateTuple
    hq_out::LSTMStateTuple
    qp::Tensor
    hqp_in::LSTMStateTuple
    hqp_out::LSTMStateTuple
    target_q::Tensor
    target_hq_in::LSTMStateTuple
    target_hq_out::LSTMStateTuple
    loss::Tensor
    td_errors::Tensor
    train_op::Tensor
    grad_norm::Tensor
    update_op::Tensor
    lstm_policy::LSTMPolicy
end

# placeholder
function build_placeholders(env::AbstractEnvironment, trace_length::Int64)
    obs_dim = obs_dimensions(env)
    n_outs = n_actions(env)
    # bs x trace_length x dim
    s = placeholder(Float32, shape=[-1, trace_length, obs_dim...])
    a = placeholder(Int32, shape=[-1, trace_length])
    sp = placeholder(Float32, shape=[-1, trace_length, obs_dim...])
    r = placeholder(Float32, shape=[-1, trace_length])
    done_mask = placeholder(Bool, shape=[-1, trace_length])
    trace_mask = placeholder(Int32, shape=[-1, trace_length])
    w = placeholder(Float32, shape=[-1])
    return s, a, sp, r, done_mask, trace_mask, w
end


function build_loss(env::AbstractEnvironment,
                    q::Tensor,
                    target_q::Tensor,
                    a::Tensor,
                    r::Tensor,
                    done_mask::Tensor,
                    trace_mask::Tensor,
                    importance_weights::Tensor)
    loss, td_errors = nothing, nothing
    variable_scope("loss") do
        # flatten time dim
        trace_length = 6
        time_mask = reshape(trace_mask, (-1))
        flat_a = reshape(a, (-1))
        flat_r = reshape(r, (-1))
        flat_done_mask = reshape(done_mask, (-1))
        term = cast(flat_done_mask, Float32)
        A = one_hot(flat_a, n_actions(env))
        q_sa = sum(A.*q, 2)
        q_samp = flat_r + (1 - term).*discount(env.problem).*maximum(target_q, 2)
        td_errors = time_mask.*(q_sa - q_samp)
        errors = huber_loss(td_errors)
        loss = sum(importance_weights.*errors)/sum(time_mask)
    end
    return loss, td_errors
end

function build_doubleq_loss(env::AbstractEnvironment,
                            q::Tensor,
                            target_q::Tensor,
                            qp::Tensor,
                            a::Tensor,
                            r::Tensor,
                            done_mask::Tensor,
                            trace_mask::Tensor,
                            importance_weights::Tensor)
    loss, td_errors = nothing, nothing
    variable_scope("loss") do
        # flatten time dim
        time_mask = reshape(trace_mask, (-1))
        flat_a = reshape(a, (-1))
        flat_r = reshape(r, (-1))
        flat_done_mask = reshape(done_mask, (-1))
        term = cast(flat_done_mask, Float32)
        A = one_hot(flat_a, n_actions(env))
        q_sa = sum(A.*q, 2)
        best_a = indmax(qp, 2)
        best_A = one_hot(best_a, n_actions(env))
        target_q_best = sum(best_A.*target_q, 2)
        q_samp = flat_r + (1 - term).*discount(env.problem).*target_q_best
        td_errors = time_mask.*(q_sa - q_samp)
        errors = huber_loss(td_errors)
        loss = sum(importance_weights.*errors)/sum(time_mask)
    end
    return loss, td_errors
end


function build_graph(solver::DeepRecurrentQLearningSolver, env::AbstractEnvironment, graph=Graph())
    sess = init_session(graph)
    s, a, sp, r, done_mask, trace_mask, w = build_placeholders(env, solver.trace_length)
    q, hq_in, hq_out = build_recurrent_q_network(s,
                                                 solver.arch.convs,
                                                 solver.arch.fc_in,
                                                 solver.arch.fc_out,
                                                 solver.arch.lstm_size,
                                                 n_actions(env),
                                                 final_activation = identity,
                                                 scope= Q_SCOPE,
                                                 dueling = solver.dueling)
    qp, hqp_in, hqp_out = build_recurrent_q_network(sp,
                                                    solver.arch.convs,
                                                    solver.arch.fc_in,
                                                    solver.arch.fc_out,
                                                    solver.arch.lstm_size,
                                                    n_actions(env),
                                                    final_activation = identity,
                                                    scope= Q_SCOPE,
                                                    reuse=true,
                                                    dueling = solver.dueling)
    target_q, target_hq_in, target_hq_out = build_recurrent_q_network(sp,
                                                                      solver.arch.convs,
                                                                      solver.arch.fc_in,
                                                                      solver.arch.fc_out,
                                                                      solver.arch.lstm_size,
                                                                      n_actions(env),
                                                                      final_activation = identity,
                                                                      scope= TARGET_Q_SCOPE,
                                                                      reuse=false,
                                                                      dueling = solver.dueling)
    if solver.double_q
        loss, td_errors = build_doubleq_loss(env, q, target_q, qp, a, r, done_mask, trace_mask, w)
    else
        loss, td_errors = build_loss(env, q, target_q, a, r, done_mask, trace_mask, w)
    end
    train_op, grad_norm = build_train_op(loss,
                                         lr=solver.lr,
                                         grad_clip=solver.grad_clip,
                                         clip_val=solver.clip_val)
    update_op = build_update_target_op(Q_SCOPE, TARGET_Q_SCOPE)
    lstm_policy = LSTMPolicy(sess, env, solver.arch, solver.dueling)
    return RecurrentTrainGraph(sess, s, a, sp, r, done_mask, trace_mask, w,
                               q, hq_in, hq_out,
                               qp, hqp_in, hqp_out,
                               target_q, target_hq_in, target_hq_out,
                               loss, td_errors, train_op, grad_norm, update_op, lstm_policy)
end
